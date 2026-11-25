#!/usr/bin/env bash
# Prove the verified copy is usable: point the llm-inference vLLM at model-store, send one
# chat completion, then restore the original Deployment. One GPU, so vLLM is restarted
# twice (a few minutes each). No sudo.
set -euo pipefail
cd "$(dirname "$0")/../.."
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
kc() { k3s kubectl -n llm-inference "$@" 2> >(grep -v k3s.yaml >&2); }
restore() {
  kc apply -f k8s/vllm/20-deployment.yaml
  kc rollout status deploy/vllm --timeout=900s
}
trap restore EXIT
patch='{"spec":{"template":{"spec":{"volumes":[{"name":"hf-cache","persistentVolumeClaim":{"claimName":"model-store"}}]}}}}'
kc patch deploy vllm --type=strategic -p "$patch"
kc rollout status deploy/vllm --timeout=900s
echo "# vLLM serving from the verified volume, $(date -Is)"
echo "claim: $(kc get deploy vllm -o jsonpath='{.spec.template.spec.volumes[?(@.name=="hf-cache")].persistentVolumeClaim.claimName}')"
ip="$(kc get svc vllm -o jsonpath='{.spec.clusterIP}')"
curl -s -m 60 "http://$ip:8000/v1/chat/completions" -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-7b-awq","messages":[{"role":"user","content":"Reply with the word ready."}],"max_tokens":8,"temperature":0}' |
  python3 -c 'import json,sys; d=json.load(sys.stdin); print("completion:", repr(d["choices"][0]["message"]["content"]))'
echo "files in model-store (refusal-test must hold no published model):"
kc exec deploy/vllm -- sh -c 'cd /root/.cache/huggingface && ls -d hub/models--*/snapshots/*; echo "refusal-test:"; find refusal-test -type f | wc -l'
