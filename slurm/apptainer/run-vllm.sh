#!/usr/bin/env bash
# Try serving the same model with vLLM from a .sif on WSL2. No sudo.
# STATUS: NOT RUN. The image pull failed twice (results/slurm/apptainer/vllm_pull_attempt*.log).
# One GPU: the k3s vLLM Deployment is scaled to 0 for the test and ALWAYS scaled back
# to 1 on exit. Needs the image and a local copy of the weights (offline):
#   apptainer pull vllm-0.32.0.sif docker://vllm/vllm-openai@sha256:befccf0e...
#   kubectl -n llm-inference exec <vllm-pod> -- tar -C /root/.cache/huggingface -cf - hub \
#     | tar -C <hf-dir> -xf -
# Usage: slurm/apptainer/run-vllm.sh /path/vllm-0.32.0.sif /path/hf-dir
set -euo pipefail
cd "$(dirname "$0")/../.."
SIF=${1:?sif path} HF=${2:?HF_HOME directory holding hub/}
OUT=results/slurm/apptainer
PORT=8002
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
export PATH="$PATH:/usr/lib/wsl/lib"
kc() { k3s kubectl -n llm-inference "$@"; }

server=""
restore() {
  [ -z "$server" ] || { kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; }
  kc scale deploy/vllm --replicas=1
}
trap restore EXIT
kc scale deploy/vllm --replicas=0
kc wait --for=delete pod -l app=vllm --field-selector=status.phase=Running --timeout=120s
sleep 10
nvidia-smi --query-gpu=memory.used --format=csv | tee "$OUT/vllm_gpu_before.txt"

# --no-home and PYTHONNOUSERSITE keep host Python packages out of the container.
start=$(date +%s)
apptainer exec --nv --no-home --writable-tmpfs --bind /usr/lib/wsl --bind "$HF:/hf" \
  --env HF_HOME=/hf --env HF_HUB_OFFLINE=1 --env PYTHONNOUSERSITE=1 "$SIF" \
  sh -c "export LD_LIBRARY_PATH=/usr/lib/wsl/lib:\${LD_LIBRARY_PATH:-}; exec vllm serve Qwen/Qwen2.5-7B-Instruct-AWQ \
    --served-model-name qwen2.5-7b-awq --quantization awq --max-model-len 4096 \
    --gpu-memory-utilization 0.80 --max-num-seqs 8 --port $PORT" >"$OUT/vllm_server.log" 2>&1 &
server=$!

until curl -sf -m 2 "http://127.0.0.1:$PORT/health" >/dev/null; do
  kill -0 "$server" 2>/dev/null || { echo "vLLM exited; see $OUT/vllm_server.log" >&2; exit 1; }
  [ $(($(date +%s) - start)) -lt 900 ] || { echo "not healthy after 900 s" >&2; exit 1; }
  sleep 5
done
echo "seconds_until_healthy=$(($(date +%s) - start))" | tee "$OUT/vllm_ready.txt"

"${PY:-.venv-test/bin/python}" -m benchmark.bench --engine vllm \
  --software-version "0.32.0 (Apptainer on WSL2)" \
  --image vllm/vllm-openai@sha256:befccf0e7e4089aa23926bb6f887a85c0d46c2a99e6de5c5ffdf5cb7957c5b34 \
  --base-url "http://127.0.0.1:$PORT/v1" --model qwen2.5-7b-awq --output-dir "$OUT/vllm_bench"
