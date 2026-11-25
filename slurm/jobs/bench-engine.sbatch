#!/usr/bin/env bash
# Phase 3 sweep for one running engine, as a job array over concurrency 1 2 4 8 16.
# %1 runs one level at a time; each task does 5 runs of its level. Submit from the repo
# root with the engine already serving, for example:
#   sbatch --export=ALL,ENGINE=vllm,NAME=vllm,VERSION=0.32.0,IMAGE=...,URL=...,MODEL=... \
#     slurm/jobs/bench-engine.sbatch
# results go to results/phase3/$NAME/, which must exist before submitting.
#SBATCH --job-name=bench-engine
#SBATCH --account=research
#SBATCH --partition=batch
#SBATCH --array=0-4%1
#SBATCH --cpus-per-task=4
#SBATCH --mem=2G
#SBATCH --time=00:10:00
#SBATCH --output=results/phase3/%x-%A_%a.out
set -euo pipefail
cd "$SLURM_SUBMIT_DIR"
LEVELS=(1 2 4 8 16)
C=${LEVELS[$SLURM_ARRAY_TASK_ID]}
export PATH="$PATH:/usr/lib/wsl/lib" # nvidia-smi on WSL2
"${PY:-.venv-test/bin/python}" -m benchmark.bench --engine "$ENGINE" \
  --software-version "$VERSION" --image "$IMAGE" --base-url "$URL" --model "$MODEL" \
  --concurrency "$C" --runs "${RUNS:-5}" --output-dir "results/phase3/$NAME"
