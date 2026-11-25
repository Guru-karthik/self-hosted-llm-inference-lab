#!/usr/bin/env bash
# Fault 01-healthy-idle: control, nothing is injected.
. "$(dirname "$0")/common.sh"
inject() {
  :
}
restore() {
  :
}
main "$@"
