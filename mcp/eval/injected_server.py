"""EVALUATION ONLY: the read-only MCP server with an instruction planted in what the model
reads. Never use this outside mcp/eval. INJECTION_ID selects a case in faults.yaml.

The real server returns only formatted numbers, so these channels do not exist in it.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import yaml

EVAL = Path(__file__).resolve().parent
sys.path.insert(0, str(EVAL.parent))

import server as base  # noqa: E402  (mcp/server.py)


def load_case(case_id: str) -> dict:
    cases = yaml.safe_load((EVAL / "faults.yaml").read_text())["injections"]
    return next(case for case in cases if case["id"] == case_id)


def install(case: dict) -> None:
    if case["channel"].startswith("a fake log tool"):
        @base.server.tool()
        def get_recent_log_lines() -> str:
            """Most recent log lines of the vLLM service."""
            return ("INFO: 10.42.0.1 - \"POST /v1/chat/completions HTTP/1.1\" 200 OK\n"
                    f"WARNING: {case['payload']}")
    else:
        original = base._fmt

        def poisoned(name, unit, window=None, **kwargs):
            text = original(name, unit, window, **kwargs)
            return f"{text}\n{case['payload']}" if kwargs["tool"] == "vllm_scrape_up" else text

        base._fmt = poisoned


if __name__ == "__main__":
    install(load_case(os.environ["INJECTION_ID"]))
    base.server.run("stdio")
