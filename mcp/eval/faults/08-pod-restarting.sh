#!/usr/bin/env bash
# Fault 08-pod-restarting: the vLLM pod is deleted and is still starting when the agent runs.
. "$(dirname "$0")/common.sh"
inject() {
  kc -n llm-inference delete pod -l app=vllm --field-selector=status.phase=Running --wait=false
}
restore() {
  wait_target
}
main "$@"
