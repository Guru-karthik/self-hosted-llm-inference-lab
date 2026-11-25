#!/usr/bin/env bash
# Fault 10-gpu-metrics-missing: the DCGM exporter is stopped by an unsatisfiable node selector.
. "$(dirname "$0")/common.sh"
inject() {
  kc -n monitoring patch daemonset dcgm-dcgm-exporter --type=merge \
    -p='{"spec":{"template":{"spec":{"nodeSelector":{"lab/disabled":"true"}}}}}'
}
restore() {
  kc -n monitoring patch daemonset dcgm-dcgm-exporter --type=json \
    -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'
  kc -n monitoring rollout status daemonset/dcgm-dcgm-exporter --timeout=300s
}
main "$@"
