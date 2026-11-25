"""Background load for the fault scripts. Runs until killed. Not a benchmark: it
records nothing and only exists to push the target vLLM into a chosen state.

--abort-after N closes each stream after N chunks (client-abort fault).
"""
from __future__ import annotations

import argparse
import random
import threading
import time

import httpx


def build_body(model: str, prompt_words: int, max_tokens: int, ignore_eos: bool) -> dict:
    # A random number first, so that vLLM's prefix cache cannot share KV blocks.
    text = f"Request {random.randrange(10**12)}. "
    if prompt_words:
        text += " ".join(["alpha"] * prompt_words) + " "
    text += "Write a long, detailed essay about the history of computing."
    body = {"model": model, "messages": [{"role": "user", "content": text}],
            "max_tokens": max_tokens, "temperature": 0, "stream": True}
    if ignore_eos:
        body["ignore_eos"] = True
    return body


def consume(lines, abort_after: int = 0) -> int:
    """Read a streamed response; stop early after abort_after non-empty lines (0 = never).

    The line iterator must be created once per response: httpx streams can only be read
    once.
    """
    count = 0
    for line in lines:
        count += bool(line)
        if abort_after and count >= abort_after:
            break
    return count


def worker(args) -> None:
    while True:
        try:
            with httpx.stream("POST", f"{args.url}/chat/completions", timeout=600,
                              json=build_body(args.model, args.prompt_words, args.max_tokens,
                                              args.ignore_eos)) as response:
                response.raise_for_status()
                consume(response.iter_lines(), args.abort_after)
        except httpx.HTTPError as error:
            print(f"{type(error).__name__}: {error}", flush=True)
            time.sleep(1)
        time.sleep(args.pause)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--url", required=True)
    p.add_argument("--model", default="qwen2.5-7b-awq")
    p.add_argument("--concurrency", type=int, default=1)
    p.add_argument("--prompt-words", type=int, default=0)
    p.add_argument("--max-tokens", type=int, default=64)
    p.add_argument("--ignore-eos", action="store_true")
    p.add_argument("--abort-after", type=int, default=0)
    p.add_argument("--pause", type=float, default=0.0)
    args = p.parse_args()
    for _ in range(args.concurrency):
        threading.Thread(target=worker, args=(args,), daemon=True).start()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
