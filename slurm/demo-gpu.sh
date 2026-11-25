#!/usr/bin/env bash
# Show what a count-only GPU GRES does and does not do. No sudo.
#  1. Two --gres=gpu:1 jobs: the second must wait for the first.
#  2. A job without --gres runs meanwhile and still tries to use nvidia-smi.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=results/slurm/gpu
mkdir -p "$OUT"

a="$(sbatch --parsable slurm/jobs/gpu-single.sbatch)"
b="$(sbatch --parsable slurm/jobs/gpu-single.sbatch)"
n="$(sbatch --parsable -J no-gres -A research -p short -c 2 --mem=1G -t 00:02:00 \
  -o "$OUT/%x-%j.out" --wrap \
  'echo "SLURM_JOB_GPUS=${SLURM_JOB_GPUS:-<unset>}"; /usr/lib/wsl/lib/nvidia-smi -L')"
sleep 8
{
  echo "\$ squeue while the first GPU job runs"
  squeue -o "%.7i %.12j %.8T %.14b %r"
} | tee "$OUT/squeue.txt"
while [ -n "$(squeue -h -j "$a,$b,$n" 2>/dev/null)" ]; do sleep 5; done
sleep 3
sacct -j "$a,$b,$n" -X -P --format=JobID,JobName,Partition,ReqTRES,Submit,Start,End,Elapsed,State |
  tee "$OUT/sacct.txt"
