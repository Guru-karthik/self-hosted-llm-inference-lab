#!/usr/bin/env bash
# Fault 07-scaled-to-zero: the vLLM Deployment has no replicas.
. "$(dirname "$0")/common.sh"
inject() {
  kc -n llm-inference scale deploy/vllm --replicas=0
}
restore() {
  kc -n llm-inference scale deploy/vllm --replicas=1
  wait_target
}
main "$@"
