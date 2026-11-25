#!/usr/bin/env bash
# Fault 05-long-outputs: very long answers; slow but not a failure.
. "$(dirname "$0")/common.sh"
inject() {
  start_load --concurrency 2 --max-tokens 2000 --ignore-eos
}
restore() {
  stop_load
}
main "$@"
