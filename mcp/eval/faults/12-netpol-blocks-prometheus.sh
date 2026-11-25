#!/usr/bin/env bash
# Fault 12-netpol-blocks-prometheus: a NetworkPolicy denies all pod ingress to vLLM, including Prometheus.
. "$(dirname "$0")/common.sh"
inject() {
  kc apply -f - <<'POLICY'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: eval-deny-ingress
  namespace: llm-inference
spec:
  podSelector:
    matchLabels:
      app: vllm
  policyTypes: [Ingress]
POLICY
}
restore() {
  kc -n llm-inference delete networkpolicy eval-deny-ingress --ignore-not-found
}
main "$@"
