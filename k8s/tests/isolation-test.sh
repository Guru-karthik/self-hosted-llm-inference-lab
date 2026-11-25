#!/usr/bin/env bash
# Automated isolation checks for the two tenants. Run with both tenant vLLMs Ready:
#     k8s/tests/isolation-test.sh | tee results/isolation/isolation-test.txt
# Every "blocked" check has a control that must succeed, and the network checks first
# run with the NetworkPolicies removed, to show that the policies are what blocks.
# It deletes and re-applies the tenant NetworkPolicies; it re-applies them on exit.
set -uo pipefail
cd "$(dirname "$0")/../.."
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
kc() { k3s kubectl "$@" 2> >(grep -v 'k3s.yaml' >&2); }
IMAGE=vllm/vllm-openai@sha256:befccf0e7e4089aa23926bb6f887a85c0d46c2a99e6de5c5ffdf5cb7957c5b34
NEUTRAL=isolation-neutral # a namespace with no policies of its own
FAILED=0

apply_tenants() { for t in tenant-a tenant-b; do kc apply -k "k8s/tenants/overlays/$t" >/dev/null; done; }
cleanup() {
  apply_tenants
  for ns in tenant-a tenant-b; do kc -n "$ns" delete pod probe over-gpu over-memory --ignore-not-found --grace-period=1 >/dev/null; done
  kc -n tenant-a delete pvc over-storage --ignore-not-found >/dev/null
  kc -n tenant-b delete secret canary --ignore-not-found >/dev/null
  kc delete ns "$NEUTRAL" --ignore-not-found >/dev/null
  kc delete -f k8s/tenants/test-client.yaml --ignore-not-found --grace-period=1 >/dev/null
}
trap cleanup EXIT
cleanup # remove leftovers of an earlier run and wait until they are gone

result() { # name expected actual
  if [ "$2" = "$3" ]; then echo "PASS  $1 (expected $2)"; else
    echo "FAIL  $1 (expected $2, got $3)"
    FAILED=$((FAILED + 1))
  fi
}
connect() { # namespace url expected(allowed|blocked) description
  echo "\$ [pod in $1] GET $2"
  local out got
  out="$(kc -n "$1" exec probe -- python3 -c '
import socket, ssl, sys, urllib.error, urllib.parse, urllib.request
url = sys.argv[1]
host = urllib.parse.urlparse(url).hostname
try:
    print("resolved", host, "->", socket.gethostbyname(host))
except OSError as e:
    print("DNS FAILED", e); sys.exit(3)
# "blocked" means no network connection. Any HTTP answer, including 401/403, is reached,
# so certificates are not verified here.
try:
    ctx = ssl._create_unverified_context()
    print("HTTP", urllib.request.urlopen(url, timeout=5, context=ctx).status)
except urllib.error.HTTPError as e:
    print("HTTP", e.code)
except Exception as e:
    print("CONNECT FAILED", type(e).__name__, getattr(e, "reason", e)); sys.exit(2)
' "$2" 2>&1)"
  case $? in 0) got=allowed ;; 2) got=blocked ;; *) got=error ;; esac
  echo "$out" | sed 's/^/    /'
  result "$4" "$3" "$got"
}
API_URL=https://kubernetes.default.svc.cluster.local/version
url() { echo "http://vllm.$1.svc.cluster.local:8000/v1/models"; }
make_probe() {
  kc -n "$1" apply -f - >/dev/null <<POD
apiVersion: v1
kind: Pod
metadata: {name: probe}
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  containers:
    - name: probe
      image: $IMAGE
      command: ["sleep", "3600"]
      resources:
        requests: {cpu: 100m, memory: 64Mi}
        limits: {cpu: 500m, memory: 256Mi}
POD
}

echo "# Tenant isolation test, $(date -Is), $(k3s --version | head -1)"
kc get pods -n tenant-a -l app=vllm
kc get pods -n tenant-b -l app=vllm
for t in tenant-a tenant-b; do
  kc -n "$t" wait --for=condition=Available deploy/vllm --timeout=30s >/dev/null || { echo "$t vLLM not ready"; exit 1; }
done
kc apply -f k8s/tenants/test-client.yaml >/dev/null
kc create ns "$NEUTRAL" >/dev/null 2>&1 || true
for ns in tenant-a tenant-b "$NEUTRAL"; do make_probe "$ns"; done
for ns in tenant-a tenant-b "$NEUTRAL" test-client; do
  kc -n "$ns" wait --for=condition=Ready pod/probe --timeout=180s >/dev/null || { echo "probe in $ns not ready"; exit 1; }
done

echo
echo "## 0. Baseline with NO NetworkPolicies in the tenants"
for t in tenant-a tenant-b; do kc -n "$t" delete networkpolicy --all; done
sleep 20
connect tenant-a "$(url tenant-b)" allowed "baseline: tenant-a reaches tenant-b"
connect "$NEUTRAL" "$(url tenant-b)" allowed "baseline: unrelated namespace reaches tenant-b"
connect tenant-a "$API_URL" allowed "baseline: tenant-a pod can reach the API server"

echo
echo "## 1. Network, with NetworkPolicies"
apply_tenants
kc get networkpolicy -n tenant-a
kc get networkpolicy -n tenant-b
sleep 45
connect tenant-a "$(url tenant-b)" blocked "tenant-a cannot reach tenant-b"
connect tenant-b "$(url tenant-a)" blocked "tenant-b cannot reach tenant-a"
connect "$NEUTRAL" "$(url tenant-b)" blocked "ingress rule alone blocks an unrelated namespace"
connect test-client "$(url tenant-a)" allowed "control: test-client reaches tenant-a"
connect test-client "$(url tenant-b)" allowed "control: test-client reaches tenant-b"
connect tenant-a "$API_URL" blocked "tenant-a pod has no egress to the API server"

prom="$(kc -n monitoring get svc kps-kube-prometheus-stack-prometheus -o jsonpath='{.spec.clusterIP}')"
for t in tenant-a tenant-b; do
  q="up{namespace=\"$t\",job=\"vllm\"}"
  echo "\$ Prometheus query: $q"
  out="$(curl -s -m 10 --data-urlencode "query=$q" "http://$prom:9090/api/v1/query")"
  echo "    $out"
  got="$(echo "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print("up" if r and r[0]["value"][1]=="1" else "down")')"
  result "Prometheus still scrapes $t" up "$got"
done

ip="$(kc -n tenant-b get svc vllm -o jsonpath='{.spec.clusterIP}')"
echo "\$ [from the node itself] curl http://$ip:8000/v1/models"
code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$ip:8000/v1/models")"
echo "    HTTP $code"
echo "NOTE  the node itself is NOT blocked by these policies (HTTP $code)"

echo
echo "## 2. API access with tenant-a's ServiceAccount token"
kc -n tenant-b create secret generic canary --from-literal=value=not-a-real-secret
token="$(kc -n tenant-a create token tenant-user --duration=10m)"
server="$(kc config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
api() { # path expected-code description
  echo "\$ GET $1"
  local out code
  out="$(curl -sk -m 10 -H "Authorization: Bearer $token" -w '\n%{http_code}' "$server$1")"
  code="${out##*$'\n'}"
  echo "    HTTP $code"
  echo "${out%$'\n'*}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("    "+(d.get("message") or d.get("kind","")))'
  result "$3" "$2" "$code"
}
api /api/v1/namespaces/tenant-a/pods 200 "control: tenant-a user lists its own pods"
api /api/v1/namespaces/tenant-b/pods 403 "tenant-a user cannot list tenant-b pods"
api /api/v1/namespaces/tenant-b/secrets 403 "tenant-a user cannot list tenant-b secrets"
api /api/v1/namespaces/tenant-b/secrets/canary 403 "tenant-a user cannot read a tenant-b secret"
api /api/v1/namespaces/tenant-a/secrets 403 "tenant-a user cannot list secrets in its own namespace"
api /api/v1/nodes 403 "tenant-a user cannot list nodes"

echo
echo "## 3. Quota"
kc -n tenant-a describe resourcequota tenant-quota
rejected() { # description yaml
  echo "\$ create: $1"
  local out got
  out="$(echo "$2" | kc -n tenant-a create -f - 2>&1)" && got=accepted || got=rejected
  [ "$got" = rejected ] && ! grep -q 'exceeded quota' <<<"$out" && got=other-error
  echo "$out" | sed 's/^/    /'
  result "$1" rejected "$got"
}
pod() { # name requests-memory extra-limits
  cat <<POD
apiVersion: v1
kind: Pod
metadata: {name: $1}
spec:
  containers:
    - name: c
      image: $IMAGE
      command: ["sleep", "60"]
      resources:
        requests: {cpu: 100m, memory: $2}
        limits: {memory: $2$3}
POD
}
rejected "pod asking for a second GPU unit" "$(pod over-gpu 128Mi ', nvidia.com/gpu: 1')"
rejected "pod whose memory request exceeds the quota" "$(pod over-memory 3Gi '')"
rejected "PVC beyond the storage and claim quota" '
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: over-storage}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 5Gi}}'

echo
echo "## Result: $FAILED failed check(s)"
exit "$((FAILED > 0))"
