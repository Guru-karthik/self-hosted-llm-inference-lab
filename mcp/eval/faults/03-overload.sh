#!/usr/bin/env bash
# Fault 03-overload: 32 clients against a server limited to 8 running requests.
. "$(dirname "$0")/common.sh"
inject() {
  start_load --concurrency 32 --max-tokens 512 --ignore-eos
}
restore() {
  stop_load
}
main "$@"
