#!/usr/bin/env bash
# Fault 06-client-aborts: clients disconnect mid-answer.
. "$(dirname "$0")/common.sh"
inject() {
  start_load --concurrency 4 --max-tokens 512 --ignore-eos --abort-after 5 --pause 0.5
}
restore() {
  stop_load
}
main "$@"
