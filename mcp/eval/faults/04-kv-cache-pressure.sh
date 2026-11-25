#!/usr/bin/env bash
# Fault 04-kv-cache-pressure: long prompts that fill the 1 GiB KV cache.
. "$(dirname "$0")/common.sh"
inject() {
  start_load --concurrency 8 --prompt-words 3300 --max-tokens 700 --ignore-eos
}
restore() {
  stop_load
}
main "$@"
