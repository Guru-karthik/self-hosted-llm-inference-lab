#!/usr/bin/env bash
# Fault 11-wrong-scrape-path: the ServiceMonitor scrapes a path that does not exist.
. "$(dirname "$0")/common.sh"
inject() {
  kc -n llm-inference patch servicemonitor vllm --type=merge \
    -p='{"spec":{"endpoints":[{"port":"http","path":"/no-such-path","interval":"15s"}]}}'
}
restore() {
  kc apply -f "$REPO/k8s/monitoring/vllm-servicemonitor.yaml"
}
main "$@"
