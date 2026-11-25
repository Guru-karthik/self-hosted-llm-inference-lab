"""Run the evaluation: for each case, wait for a quiet healthy target, inject the fault,
wait, run mcp/agent.py, save everything, restore the target.

    python mcp/eval/runner.py --out results/mcp-eval/run1                # the 12 faults
    python mcp/eval/runner.py --out results/mcp-eval/inj1 --injections   # injection cases

Needs the environment from mcp/eval/env.sh (a separate vLLM serves the agent, so that
breaking the target does not remove the agent's own model). Verdicts are NOT produced
here; see score.py.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import httpx
import yaml

EVAL = Path(__file__).resolve().parent
MCP = EVAL.parent
sys.path.insert(0, str(MCP))

from prom import parse_instant, query_for  # noqa: E402

SIGNALS = ["vllm_scrape_up", "requests_running", "requests_waiting", "kv_cache_usage_ratio",
           "p95_latency_seconds", "p95_ttft_seconds", "error_rate", "gpu_utilisation_percent",
           "gpu_memory_used_mib", "gpu_temperature_celsius"]
INJECTION_LOAD = "03-overload"


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def cluster_ip(namespace: str, service: str) -> str:
    return subprocess.run(
        ["k3s", "kubectl", "-n", namespace, "get", "svc", service, "-o", "jsonpath={.spec.clusterIP}"],
        check=True, capture_output=True, text=True,
        env={"KUBECONFIG": str(Path.home() / ".kube/config"), **os.environ},
    ).stdout.strip()


def snapshot(prom_url: str) -> dict:
    """What the metrics showed when the agent started, to check that a fault took effect."""
    values = {}
    for name in SIGNALS:
        try:
            response = httpx.get(f"{prom_url}/api/v1/query", params={"query": query_for(name)}, timeout=10)
            values[name] = parse_instant(response.json()).value
        except (httpx.HTTPError, RuntimeError, ValueError) as error:
            values[name] = f"error: {error}"
    return values


def fault_script(fault_id: str, action: str, log: Path) -> None:
    with log.open("a") as handle:
        handle.write(f"$ {fault_id}.sh {action}  ({now()})\n")
        handle.flush()
        subprocess.run([str(EVAL / "faults" / f"{fault_id}.sh"), action], check=True,
                       stdout=handle, stderr=subprocess.STDOUT, timeout=1200)


def wait_healthy(target_url: str, prom_url: str, timeout: float = 900) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            healthy = httpx.get(f"{target_url}/health", timeout=5).status_code == 200
            if healthy and snapshot(prom_url)["vllm_scrape_up"] == 1:
                return
        except httpx.HTTPError:
            pass
        time.sleep(5)
    raise RuntimeError("target did not become healthy and scraped")


def run_case(case: dict, args, question: str) -> None:
    out = args.out / case["id"]
    if (out / "meta.json").exists():
        print(f"{case['id']}: already done, skipping")
        return
    out.mkdir(parents=True, exist_ok=True)
    injection = "channel" in case
    fault_id = INJECTION_LOAD if injection else case["id"]
    settle = args.injection_settle if injection else case["settle_seconds"]

    wait_healthy(args.target_url, args.prom_url)
    print(f"{case['id']}: quiet period {args.cooldown} s", flush=True)
    time.sleep(args.cooldown)  # so that the 5 min metric windows do not contain the last case
    meta = {"case": case["id"], "fault": fault_id, "settle_seconds": settle,
            "cooldown_seconds": args.cooldown, "model": args.model, "started": now()}
    env = {**os.environ, "INJECTION_ID": case["id"] if injection else ""}
    try:
        fault_script(fault_id, "inject", out / "fault.log")
        time.sleep(settle)
        meta["agent_started"] = now()
        meta["signals_at_agent_start"] = snapshot(args.prom_url)
        command = [sys.executable, str(MCP / "agent.py"), "--llm-url", args.llm_url,
                   "--model", args.model, "--prometheus-url", args.prom_url,
                   "--question", question, "--tool-log", str(out / "tool_calls.jsonl"),
                   "--transcript-json", str(out / "transcript.json")]
        if injection:
            command += ["--server", str(EVAL / "injected_server.py")]
        agent = subprocess.run(command, capture_output=True, text=True, timeout=600, env=env)
        (out / "transcript.txt").write_text(agent.stdout + (f"\n--- stderr ---\n{agent.stderr}" if agent.returncode else ""))
        meta["agent_exit_code"] = agent.returncode
    finally:
        fault_script(fault_id, "restore", out / "fault.log")
    meta["finished"] = now()
    (out / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(f"{case['id']}: done (agent exit {meta['agent_exit_code']})", flush=True)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--injections", action="store_true", help="run the prompt-injection cases")
    p.add_argument("--only", nargs="+", help="case ids")
    p.add_argument("--model", default="qwen2.5-7b-awq")
    p.add_argument("--llm-url", help="agent model (default: tenant-a vLLM)")
    p.add_argument("--target-url", help="system under test (default: llm-inference vLLM)")
    p.add_argument("--prom-url")
    p.add_argument("--cooldown", type=int, default=300)
    p.add_argument("--injection-settle", type=int, default=120)
    args = p.parse_args()
    args.llm_url = args.llm_url or f"http://{cluster_ip('tenant-a', 'vllm')}:8000/v1"
    args.target_url = args.target_url or f"http://{cluster_ip('llm-inference', 'vllm')}:8000"
    args.prom_url = args.prom_url or f"http://{cluster_ip('monitoring', 'kps-kube-prometheus-stack-prometheus')}:9090"
    labels = yaml.safe_load((EVAL / "faults.yaml").read_text())
    cases = labels["injections" if args.injections else "faults"]
    for case in cases:
        if not args.only or case["id"] in args.only:
            run_case(case, args, labels["question"])


if __name__ == "__main__":
    main()
