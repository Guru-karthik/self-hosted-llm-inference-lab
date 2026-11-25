#!/usr/bin/env bash
# Benchmark sweep as a job array: concurrency {1,2,4,8} x repeat {1,2,3} = 12 tasks.
# %1 runs one task at a time, so tasks never load the same vLLM server together.
# The server is the k3s vLLM Deployment, outside Slurm's control; the job is only the
# client, so it requests no GPU. Submit from the repo root:
#     sbatch slurm/jobs/bench-array.sbatch
# Overrides (environment): VLLM_URL, PY (a Python with benchmark/requirements.txt).
#SBATCH --job-name=bench-sweep
#SBATCH --account=research
#SBATCH --partition=batch
#SBATCH --array=0-11%1
#SBATCH --cpus-per-task=4
#SBATCH --mem=2G
#SBATCH --time=00:10:00
#SBATCH --output=results/slurm/bench/%x-%A_%a.out
set -euo pipefail
cd "$SLURM_SUBMIT_DIR"

LEVELS=(1 2 4 8)
C=${LEVELS[$((SLURM_ARRAY_TASK_ID % 4))]}
R=$((SLURM_ARRAY_TASK_ID / 4 + 1))
PY=${PY:-$SLURM_SUBMIT_DIR/.venv-test/bin/python}
export PATH="$PATH:/usr/lib/wsl/lib" # nvidia-smi on WSL2
if [ -z "${VLLM_URL:-}" ]; then
  ip="$(KUBECONFIG=$HOME/.kube/config k3s kubectl -n llm-inference get svc vllm -o jsonpath='{.spec.clusterIP}')"
  VLLM_URL="http://$ip:8000/v1"
fi

echo "task=$SLURM_ARRAY_TASK_ID concurrency=$C repeat=$R url=$VLLM_URL"
"$PY" -m benchmark.bench --engine vllm \
  --software-version "0.32.0 (k3s, ClusterIP, Slurm client)" \
  --image vllm/vllm-openai@sha256:befccf0e7e4089aa23926bb6f887a85c0d46c2a99e6de5c5ffdf5cb7957c5b34 \
  --base-url "$VLLM_URL" --model qwen2.5-7b-awq \
  --concurrency "$C" --output-dir "results/slurm/bench/c${C}_r${R}"
