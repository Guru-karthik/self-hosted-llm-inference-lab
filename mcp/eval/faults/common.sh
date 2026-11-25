# Shared helpers for the fault scripts. Each script takes "inject" or "restore" and
# changes only the lab's llm-inference or monitoring namespace. No sudo.
set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
EVAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$EVAL_DIR/../.." && pwd)"
STATE=${EVAL_STATE:-$REPO/logs/eval-state} # PID files and saved settings (ignored by git)
PY=${PY:-$REPO/.venv-mcp/bin/python}
mkdir -p "$STATE"

kc() { k3s kubectl "$@"; }
target_url() { echo "http://$(kc -n llm-inference get svc vllm -o jsonpath='{.spec.clusterIP}'):8000/v1"; }
start_load() { # loadgen arguments
  nohup "$PY" "$EVAL_DIR/loadgen.py" --url "$(target_url)" "$@" >"$STATE/loadgen.log" 2>&1 &
  echo $! >"$STATE/loadgen.pid"
}
stop_load() {
  if [ -f "$STATE/loadgen.pid" ]; then
    kill "$(cat "$STATE/loadgen.pid")" 2>/dev/null || true
    rm -f "${STATE:?}/loadgen.pid"
  fi
}
wait_target() {
  kc -n llm-inference rollout status deploy/vllm --timeout=900s
  local url
  url="$(target_url)"
  until curl -sf -m 5 "${url%/v1}/health" >/dev/null; do sleep 3; done
}
main() {
  case "${1:-}" in
    inject) inject ;;
    restore) restore ;;
    *) echo "usage: $0 inject|restore" >&2; exit 2 ;;
  esac
}
