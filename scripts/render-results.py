#!/usr/bin/env python3
"""Generate the benchmark tables of the README and the report from files in results/, so numbers cannot drift.

    python scripts/render-results.py          # rewrite the blocks in README.md
    python scripts/render-results.py --check  # exit 1 if README.md is out of date

Each table sits between <!-- BEGIN generated: NAME --> and <!-- END generated: NAME -->
in README.md or docs/report.md. In the report each table also names its source files.
Result files are named explicitly: a new run changes the README only on purpose.
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "results"
LEVELS = [1, 2, 4, 8, 16]


def load(path: str) -> list[dict]:
    return json.loads((RESULTS / path).read_text())["summary"]


def table(header: list[str], rows: list[list[str]]) -> str:
    lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    lines += ["| " + " | ".join(row) + " |" for row in rows]
    return "\n".join(lines)


def ok(summary: dict) -> str:
    return f"{summary['success_count']}/{summary['request_count']}"


def single_runs() -> str:
    setups = [
        ("Ollama 0.40.13, GGUF Q4_K_M (Docker)", "ollama_20261029T112426.441496Z.json"),
        ("vLLM 0.32.0, AWQ 4-bit (Docker)", "vllm_20261029T121246.269036Z.json"),
        ("vLLM 0.32.0, AWQ 4-bit (k3s, via port-forward)", "k8s/vllm_20261029T154626.064016Z.json"),
    ]
    rows = [
        [name, str(s["concurrency"]), ok(s), f"{s['ttft_p50_seconds']:.3f}", f"{s['ttft_p95_seconds']:.3f}",
         f"{s['tokens_per_second_p50']:.1f}", f"{s['end_to_end_p50_seconds']:.3f}",
         f"{s['end_to_end_p95_seconds']:.3f}", str(s["peak_vram_mib"])]
        for name, path in setups for s in load(path)
    ]
    return table(["Setup", "Concurrency", "OK", "TTFT p50", "TTFT p95", "Tok/s p50", "E2E p50", "E2E p95",
                  "Peak VRAM"], rows)


def sharing() -> str:
    setups = [
        ("Pod A alone", "sharing/a_alone/vllm_20261029T213921.902587Z.json"),
        ("Pod A, with B also under load", "sharing/a_with_b/vllm_20261029T214158.035033Z.json"),
        ("Pod B, with A also under load", "sharing/b_with_a/vllm_20261029T214158.049826Z.json"),
    ]
    rows = [
        [name, str(s["concurrency"]), ok(s), f"{s['ttft_p50_seconds']:.3f}", f"{s['tokens_per_second_p50']:.1f}",
         f"{s['end_to_end_p50_seconds']:.3f}", f"{s['end_to_end_p95_seconds']:.3f}"]
        for name, path in setups for s in load(path)
    ]
    return table(["Setup", "Concurrency", "OK", "TTFT p50", "Tok/s p50", "E2E p50", "E2E p95"], rows)


def startup() -> str:
    def column(path: str) -> str:
        with (RESULTS / "startup" / path).open(newline="") as handle:
            return ", ".join(row["seconds_to_first_completion"] for row in csv.DictReader(handle))

    return table(["Case", "Seconds"], [
        ["k3s, scale 0 to 1, weights already in PVC (3 runs)", column("k8s_warm_pvc_20261029.csv")],
        ["Docker, weights already in volume (1 run)", column("docker_warm_20261029.csv")],
        ["Docker, empty volume: weights downloaded from Hugging Face (1 run)", column("docker_cold_20261029.csv")],
    ])


def level_summaries(directory: Path) -> dict[int, dict]:
    summaries = [s for path in sorted(directory.glob("*.json"))
                 for s in json.loads(path.read_text())["summary"]]
    by_level = {s["concurrency"]: s for s in summaries}
    if len(by_level) != len(summaries) or sorted(by_level) != LEVELS:
        raise ValueError(f"{directory}: expected exactly one result for each level {LEVELS}")
    return by_level


def interval(summary: dict, metric: str, digits: int) -> str:
    stats = summary["across_runs"][metric]
    half = stats["ci95_high"] - stats["mean"]
    return f"{stats['mean']:.{digits}f} ± {half:.{digits}f}"


def repeated_runs() -> str:
    setups = [("vLLM 0.32.0, AWQ", "vllm"), ("Ollama 0.40.13, defaults (1 slot)", "ollama-default"),
              ("Ollama 0.40.13, tuned (8 slots)", "ollama-tuned")]
    rows = []
    for name, directory in setups:
        by_level = level_summaries(RESULTS / "phase3" / directory)
        for level in LEVELS:
            s = by_level[level]
            rows.append([name, str(level), ok(s), interval(s, "ttft_p50_seconds", 3),
                         interval(s, "tokens_per_second_p50", 1), interval(s, "end_to_end_p50_seconds", 3),
                         interval(s, "aggregate_output_tokens_per_second", 1), str(s["peak_vram_mib"])])
    return table(["Setup", "Concurrency", "OK", "TTFT p50 (s)", "Tok/s per request p50", "E2E p50 (s)",
                  "Aggregate output tok/s", "Peak VRAM"], rows)


def slurm_array() -> str:
    rows = []
    for level in [1, 2, 4, 8]:
        runs = [json.loads(path.read_text())["summary"][0]
                for path in sorted((RESULTS / "slurm" / "bench").glob(f"c{level}_r*/*.json"))]

        def spread(metric: str, digits: int) -> str:
            low, high = (f"{pick(r[metric] for r in runs):.{digits}f}" for pick in (min, max))
            return low if low == high else f"{low} to {high}"

        rows.append([str(level), spread("ttft_p50_seconds", 3), spread("tokens_per_second_p50", 1),
                     spread("end_to_end_p50_seconds", 3)])
    return table(["Concurrency", "TTFT p50 (s), min to max of 3", "Tok/s p50", "E2E p50 (s)"], rows)


TABLES = {"single-runs": single_runs, "startup": startup, "sharing": sharing,
          "repeated-runs": repeated_runs, "slurm-array": slurm_array}


SOURCES = {
    "single-runs": "results/ollama_20261029T112426.441496Z.json, results/vllm_20261029T121246.269036Z.json, "
                   "results/k8s/vllm_20261029T154626.064016Z.json",
    "startup": "results/startup/*.csv",
    "sharing": "results/sharing/a_alone/, results/sharing/a_with_b/, results/sharing/b_with_a/",
    "repeated-runs": "results/phase3/vllm/, results/phase3/ollama-default/, results/phase3/ollama-tuned/",
    "slurm-array": "results/slurm/bench/",
}
# Document -> (tables it contains, whether each table is followed by its source files).
TARGETS = {
    "README.md": (list(TABLES), False),
    "docs/report.md": (["repeated-runs", "startup", "sharing"], True),
}


def block(name: str, with_source: bool) -> str:
    body = TABLES[name]()
    return f"{body}\n\nSource: `{SOURCES[name]}`" if with_source else body


def render_document(text: str, names: list[str], with_source: bool) -> str:
    for name in names:
        text = render(text, name, block(name, with_source))
    return text


def render(text: str, name: str, body: str) -> str:
    pattern = re.compile(f"(<!-- BEGIN generated: {name} -->\n).*?(\n<!-- END generated: {name} -->)", re.S)
    new, count = pattern.subn(lambda m: m.group(1) + body + m.group(2), text)
    if count != 1:
        raise ValueError(f"README needs exactly one generated block named {name!r}, found {count}")
    return new


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    stale = []
    for path, (names, with_source) in TARGETS.items():
        document = ROOT / path
        old = document.read_text()
        new = render_document(old, names, with_source)
        if new == old:
            continue
        stale.append(path)
        if not args.check:
            document.write_text(new)
    if args.check and stale:
        print(f"Tables differ from results/ in {', '.join(stale)}; run scripts/render-results.py", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
