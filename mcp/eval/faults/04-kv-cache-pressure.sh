#!/usr/bin/env bash
# Fault 04-kv-cache-pressure: long prompts that fill the 1 GiB KV cache.
. "$(dirname "$0")/common.sh"
inject() {
  start_load --concurrency 8 --prompt-words 2800 --max-tokens 600 --ignore-eos
}
restore() {
  stop_load
}
main "$@"
