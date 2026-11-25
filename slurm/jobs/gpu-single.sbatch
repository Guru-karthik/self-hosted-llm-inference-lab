#!/usr/bin/env bash
# Single-GPU job: asks Slurm for the one GPU and records what it can actually see.
# Slurm's GPU here is count-only (see slurm/gres.conf). Submit from the repo root:
#     sbatch slurm/jobs/gpu-single.sbatch
#SBATCH --job-name=gpu-single
#SBATCH --account=research
#SBATCH --partition=short
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=2
#SBATCH --mem=1G
#SBATCH --time=00:05:00
#SBATCH --output=results/slurm/gpu/%x-%j.out
set -euo pipefail
export PATH="$PATH:/usr/lib/wsl/lib" # nvidia-smi on WSL2

echo "job=$SLURM_JOB_ID"
echo "SLURM_JOB_GPUS=${SLURM_JOB_GPUS:-<unset>}"
echo "SLURM_GPUS_ON_NODE=${SLURM_GPUS_ON_NODE:-<unset>}"
echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<unset>}"
nvidia-smi --query-gpu=name,memory.total,memory.used,utilization.gpu --format=csv
sleep "${HOLD_SECONDS:-30}" # hold the GRES long enough to see a second job queue
