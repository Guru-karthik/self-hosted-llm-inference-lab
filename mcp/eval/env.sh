#!/usr/bin/env bash
# Set up or revert the evaluation environment. No sudo. Changes the cluster:
#   up:   GPU time-slicing (2 units); the target llm-inference vLLM gets the fixed 1 GiB
#         KV cache needed to share the GPU; tenant-a runs the agent's model.
#   down: reverts all three.
set -euo pipefail
cd "$(dirname "$0")/../.."
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
HELM=${HELM:-$HOME/.local/bin/helm}
NVDP=0.20.1
kc() { k3s kubectl "$@"; }
plugin() { # extra helm arguments, then the expected GPU count
  local want=${*: -1}
  "$HELM" upgrade nvdp nvdp/nvidia-device-plugin -n nvidia-device-plugin --version "$NVDP" \
    --reset-values "${@:1:$#-1}" >/dev/null
  kc -n nvidia-device-plugin rollout status ds/nvdp-nvidia-device-plugin --timeout=180s
  until [ "$(kc get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}')" = "$want" ]; do sleep 4; done
}
case "${1:-}" in
  up)
    kc -n llm-inference scale deploy/vllm --replicas=0
    kc -n llm-inference wait --for=delete pod -l app=vllm --field-selector=status.phase=Running --timeout=180s || true
    plugin -f k8s/sharing/device-plugin-timeslicing-values.yaml 2
    kc -n llm-inference patch deploy vllm --type=json -p="$(python3 - <<'PY'
import json
args = ["--model=Qwen/Qwen2.5-7B-Instruct-AWQ", "--served-model-name=qwen2.5-7b-awq",
        "--quantization=awq", "--max-model-len=4096", "--kv-cache-memory-bytes=1073741824",
        "--max-num-seqs=8", "--enable-auto-tool-choice", "--tool-call-parser=hermes"]
print(json.dumps([{"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": args}]))
PY
)"
    kc -n llm-inference scale deploy/vllm --replicas=1
    kc -n llm-inference rollout status deploy/vllm --timeout=900s
    k3s kubectl kustomize mcp/eval/agent-llm | kc apply -f -
    kc -n tenant-a scale deploy/vllm --replicas=1
    kc -n tenant-a rollout status deploy/vllm --timeout=900s
    ;;
  down)
    kc -n tenant-a scale deploy/vllm --replicas=0
    kc apply -k k8s/tenants/overlays/tenant-a
    kc -n tenant-a scale deploy/vllm --replicas=0
    kc -n llm-inference scale deploy/vllm --replicas=0
    kc -n llm-inference wait --for=delete pod -l app=vllm --field-selector=status.phase=Running --timeout=180s || true
    plugin --set runtimeClassName=nvidia 1
    kc apply -f k8s/vllm/20-deployment.yaml
    kc -n llm-inference scale deploy/vllm --replicas=1
    kc -n llm-inference rollout status deploy/vllm --timeout=900s
    ;;
  *) echo "usage: $0 up|down" >&2; exit 2 ;;
esac
kc get pods -A | grep -E 'vllm' || true
