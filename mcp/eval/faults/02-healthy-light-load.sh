#!/usr/bin/env bash
# Fault 02-healthy-light-load: control, one client with short requests.
. "$(dirname "$0")/common.sh"
inject() {
  start_load --concurrency 1 --max-tokens 64 --pause 1
}
restore() {
  stop_load
}
main "$@"
