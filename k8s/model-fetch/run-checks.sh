#!/usr/bin/env bash
# Run the fetch Job in the cluster: the real manifest (must pass), then three altered
# runs (must be refused and publish nothing). No sudo. Output goes to results/model-fetch/.
#     k8s/model-fetch/run-checks.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
D=k8s/model-fetch OUT=results/model-fetch
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp:?}"' EXIT
mkdir -p "$OUT"
kc() { k3s kubectl -n llm-inference "$@" 2> >(grep -v k3s.yaml >&2); }

run_job() { # job-name log-file expected(Complete|Failed)
  local started=$SECONDS status=""
  until [ -n "$status" ]; do
    sleep 3
    status="$(kc get job "$1" -o jsonpath='{.status.conditions[?(@.status=="True")].type}')"
    [ $((SECONDS - started)) -lt 900 ] || { echo "timeout" >&2; return 1; }
  done
  { echo "# job $1, $(date -Is), condition: $status, wall: $((SECONDS - started)) s"; kc logs "job/$1"; } | tee "$OUT/$2"
  grep -qw "$3" <<<"$status" || { echo "FAIL: $1 should have ended $3" >&2; exit 1; }
}

kc delete job model-fetch --ignore-not-found
kc apply -k "$D"
run_job model-fetch verified.txt Complete

variant() { # name max-bytes python-edit-of-the-manifest
  python3 -c "import json; m=json.load(open('$D/manifests/qwen2.5-7b-awq.json')); $3; json.dump(m, open('$tmp/manifest.json','w'))"
  kc delete job "$1" --ignore-not-found
  kc delete configmap "$1" --ignore-not-found
  kc create configmap "$1" --from-file="$D/fetch.py" --from-file="$tmp/manifest.json"
  # Take the Job from the rendered kustomization and change only name, limit and folder.
  kc create --dry-run=client -o json -k "$D" | python3 -c '
import json, sys
name, limit = sys.argv[1], sys.argv[2]
text = sys.stdin.read()
decoder, index, objects = json.JSONDecoder(), 0, []
while index < len(text.rstrip()):
    value, index = decoder.raw_decode(text, index)
    objects += value.get("items", [value])
    while index < len(text) and text[index].isspace():
        index += 1
job = next(o for o in objects if o["kind"] == "Job")
job["metadata"] = {"name": name, "namespace": "llm-inference"}
spec = job["spec"]["template"]["spec"]
args = spec["containers"][0]["args"]
spec["containers"][0]["args"] = [
    f"--max-bytes={limit}" if a.startswith("--max-bytes=") else
    "--dest=/models/refusal-test" if a.startswith("--dest=") else a for a in args]
next(v for v in spec["volumes"] if v["name"] == "code")["configMap"]["name"] = name
print(json.dumps(job))
' "$1" "$2" | kc apply -f -
  run_job "$1" "$1.txt" Failed
  kc delete job "$1"
  kc delete configmap "$1"
}

variant refuse-digest 8000000000 'next(f for f in m["files"] if f["path"]=="config.json")["digest"]="0"*40'
variant refuse-size 1000000000 'pass'
variant refuse-format 8000000000 'm["files"].append({"path":"pytorch_model.bin","size":1,"algorithm":"sha256","digest":"0"*64})'
