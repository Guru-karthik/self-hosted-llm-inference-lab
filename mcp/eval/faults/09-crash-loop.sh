#!/usr/bin/env bash
# Fault 09-crash-loop: an invalid argument makes the vLLM container crash repeatedly.
. "$(dirname "$0")/common.sh"
inject() {
  kc -n llm-inference get deploy vllm -o jsonpath='{.spec.template.spec.containers[0].args}' >"$STATE/vllm-args.json"
  kc -n llm-inference patch deploy vllm --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--no-such-flag"}]'
}
restore() {
  kc -n llm-inference patch deploy vllm --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":$(cat "$STATE/vllm-args.json")}]"
  wait_target
}
main "$@"
