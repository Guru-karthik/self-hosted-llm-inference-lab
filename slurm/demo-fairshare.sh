#!/usr/bin/env bash
# Show how fair-share, QoS and partition factors reorder a queue. No sudo.
# Each stage: a blocker job takes all 16 CPUs, jobs queue behind it, we record the
# priorities, release the blocker and record the order in which jobs actually started.
# Every queued job also asks for 16 CPUs, so they run strictly one at a time.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=results/slurm/fairshare
mkdir -p "$OUT"

submit() { # name account partition qos seconds
  sbatch --parsable -J "$1" -A "$2" -p "$3" --qos="$4" -c 16 -t 00:05:00 \
    -o /dev/null --wrap "sleep $5"
}
wait_for() { # job ids: wait until none is left in the queue
  local list
  list="$(IFS=,; echo "$*")"
  while [ -n "$(squeue -h -j "$list" 2>/dev/null)" ]; do sleep 5; done
}
shares() {
  echo "\$ sshare -a -l"
  sshare -a -o Account,RawShares,NormShares,RawUsage,EffectvUsage,FairShare,LevelFS
}
snapshot() {
  echo "\$ sprio -l"
  sprio -o "%.7i %.9r %.10Y %.10F %.8A %.8Q %.10P"
  echo "(factor columns are already multiplied by their weights)"
  echo "\$ squeue (sorted by priority)"
  squeue --sort=-p -o "%.7i %.14j %.9a %.7q %.6P %.8T %.10Q %r"
}
started() { # job ids: print them in actual start order
  local list
  list="$(IFS=,; echo "$*")"
  echo "\$ sacct (sorted by start time)"
  sacct -j "$list" -X -P --format=JobID,JobName,Account,QOS,Partition,Submit,Start,End,Elapsed,State |
    { read -r header; echo "$header"; sort -t'|' -k7,7; }
}
run_stage() { # file title, then one "name account partition qos" per queued job
  local file="$OUT/$1.txt" blocker ids=() spec
  echo "# $2" >"$file"
  shift 2
  blocker="$(submit blocker research batch normal 600)"
  # Without this wait a higher-priority job can start before the blocker does.
  until [ "$(squeue -h -j "$blocker" -o %T)" = RUNNING ]; do sleep 1; done
  for spec in "$@"; do
    read -r n a p q <<<"$spec"
    ids+=("$(submit "$n" "$a" "$p" "$q" 20)")
    sleep 2
  done
  echo "submission order: ${ids[*]}" >>"$file"
  sleep 70 # longer than PriorityCalcPeriod (1 min)
  { shares; snapshot; } >>"$file"
  scancel "$blocker"
  wait_for "${ids[@]}"
  started "${ids[@]}" >>"$file"
  cat "$file"
}

[ -z "$(squeue -h)" ] || { echo "Queue is not empty; stop other jobs first." >&2; exit 1; }

# Optional argument: one stage name to re-run alone, e.g. 3_qos (usage is not re-created).
ONLY=${1:-}
stage() { if [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; then run_stage "$@"; fi; }

if [ -z "$ONLY" ]; then
  { echo "# Before the demo"; scontrol show config | grep -E '^Priority'; shares; } >"$OUT/0_before.txt"

  # Let "research" use the node so that its fair-share factor drops.
  usage=()
  for i in 1 2 3; do usage+=("$(submit "usage$i" research batch normal 60)"); done
  wait_for "${usage[@]}"
  sleep 70
  { echo "# After research used 3 x 60 s on 16 CPUs; teaching used nothing"; shares; } >"$OUT/1_usage.txt"
fi

stage 2_fairshare "research submits first, teaching second: who starts first?" \
  "res-A research batch normal" "res-B research batch normal" \
  "tea-A teaching batch normal" "tea-B teaching batch normal"
stage 3_qos "research job with QoS high submitted last" \
  "tea-C teaching batch normal" "tea-D teaching batch normal" \
  "res-high research batch high"
stage 4_partition "same account: batch job submitted before a short-partition job" \
  "res-batch research batch normal" "res-short research short normal"
