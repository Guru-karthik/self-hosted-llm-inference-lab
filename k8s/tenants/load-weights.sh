#!/usr/bin/env bash
# Copy model weights into one tenant's PVC through a temporary pod, because pods here
# cannot download from Hugging Face (docs/pod-network-download-issue.md). No checksum
# verification. Leaves the tenant's vLLM scaled to 0. Usage:
#     k8s/tenants/load-weights.sh tenant-a /path/to/hf-home    # directory holding hub/
set -euo pipefail
cd "$(dirname "$0")/../.."
NS=${1:?tenant namespace} SRC=${2:?directory containing hub/}
[ -d "$SRC/hub" ] || { echo "$SRC/hub not found" >&2; exit 1; }
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
kc() { k3s kubectl -n "$NS" "$@"; }

kc apply -k "k8s/tenants/overlays/$NS"
kc scale deploy/vllm --replicas=0
trap 'kc delete pod cache-loader --ignore-not-found --wait=false' EXIT
kc apply -f - <<'POD'
apiVersion: v1
kind: Pod
metadata:
  name: cache-loader
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  containers:
    - name: loader
      image: vllm/vllm-openai@sha256:befccf0e7e4089aa23926bb6f887a85c0d46c2a99e6de5c5ffdf5cb7957c5b34
      command: ["sleep", "3600"]
      resources:
        requests: {cpu: 100m, memory: 128Mi}
        limits: {cpu: "2", memory: 1Gi}
      volumeMounts:
        - name: hf-cache
          mountPath: /cache
  volumes:
    - name: hf-cache
      persistentVolumeClaim:
        claimName: hf-cache
POD
kc wait --for=condition=Ready pod/cache-loader --timeout=180s
tar -C "$SRC" -cf - hub | kc exec -i cache-loader -- tar -C /cache -xf -
kc exec cache-loader -- du -sh /cache/hub
