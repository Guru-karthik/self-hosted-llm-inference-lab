<!-- Short technical report on the lab (Phase R). Tables between the markers are generated
     from results/ by scripts/render-results.py and checked in CI; do not edit them by hand. -->
# Serving a 7B model on one GPU: measurements, isolation and operations

*Technical report on a single-machine lab, 2026-10-29 and 2026-11-25. Every number comes from a file in [`results/`](../results/) or from [`LOG.md`](../LOG.md).*

## 1. Question

A university IT centre that offers model inference to several groups has to answer practical questions before it buys or shares hardware. This lab asks small versions of four of them on one consumer GPU:

1. How do two common serving engines behave when several requests arrive at once, and how much of the difference is configuration?
2. What does it cost to start a model server from zero, and what happens when two servers share one GPU?
3. Which parts of a two-tenant setup on Kubernetes can be shown to be isolated, and which cannot?
4. Can a small local model, given read-only monitoring tools, help an operator diagnose faults?

The answers are limited to one machine. Nothing here is a capacity plan, a security assessment or a reliability study.

## 2. Setup

| Item | Value |
|---|---|
| GPU | NVIDIA GeForce RTX 5070 Ti, 16,303 MiB |
| CPU and memory | AMD Ryzen 7 9700X (16 logical CPUs); 15 GiB visible inside WSL2 |
| Operating system | Ubuntu 24.04.4 LTS on WSL2, kernel 6.18.33.2-microsoft-standard-WSL2 |
| Engines | vLLM 0.32.0 with `Qwen/Qwen2.5-7B-Instruct-AWQ`; Ollama 0.40.13 with `qwen2.5:7b-instruct-q4_K_M` (GGUF); images pinned by digest |
| Kubernetes | k3s v1.36.5+k3s1, single node; NVIDIA device plugin 0.20.1 |
| Monitoring | kube-prometheus-stack 92.15.0, dcgm-exporter 4.8.4 |
| Batch scheduling | Slurm 23.11.4 sandbox on the same machine; Apptainer 1.5.5 |
| Operations agent | MCP Python SDK 2.3.0; 8 read-only tools with fixed Prometheus queries |

Sources: README environment table, [`results/slurm/versions.txt`](../results/slurm/versions.txt).

## 3. Method

**Load.** [`benchmark/bench.py`](../benchmark/bench.py) sends streaming chat requests from a fixed set of 8 prompts, 2 repeats each (16 requests per batch), `max_tokens=64`, `temperature=0`, after one warm-up request. It records time to first token (TTFT), completion tokens per second after the first token (per request), end-to-end latency, failures and peak GPU memory.

**Repetition.** The 2026-11-25 sweeps run each concurrency level (1, 2, 4, 8, 16) five times back to back. For each run it takes the median TTFT, tokens per second and latency, plus aggregate throughput (all output tokens divided by the wall time of the batch). Tables give the mean over the five runs and the half-width of the 95% confidence interval (Student t, 4 degrees of freedom). The earlier results are single runs.

**Engines.** One engine used the GPU at a time. vLLM ran with `--max-model-len 4096 --gpu-memory-utilization 0.80 --max-num-seqs 8`. Ollama ran with defaults (it reported `OLLAMA_NUM_PARALLEL:1`) and, separately, with `OLLAMA_NUM_PARALLEL=8` and `OLLAMA_CONTEXT_LENGTH=4096`.

**Isolation checks.** An automated script first removes the NetworkPolicies to show that traffic then flows, applies them, and checks that each blocked path has a control that still works.

**Operations agent.** Twelve faults with expected diagnoses written beforehand; the agent is asked the same question after each is injected. A second vLLM instance serves the agent, so breaking the target does not remove the agent's model.

## Repeated runs

<!-- BEGIN generated: repeated-runs -->
| Setup | Concurrency | OK | TTFT p50 (s) | Tok/s per request p50 | E2E p50 (s) | Aggregate output tok/s | Peak VRAM |
|---|---|---|---|---|---|---|---|
| vLLM 0.32.0, AWQ | 1 | 80/80 | 0.026 ± 0.002 | 140.8 ± 0.3 | 0.480 ± 0.002 | 132.7 ± 0.7 | 14358 |
| vLLM 0.32.0, AWQ | 2 | 80/80 | 0.030 ± 0.005 | 142.1 ± 0.8 | 0.481 ± 0.005 | 263.4 ± 2.1 | 14346 |
| vLLM 0.32.0, AWQ | 4 | 80/80 | 0.049 ± 0.006 | 141.2 ± 1.5 | 0.501 ± 0.004 | 504.2 ± 4.1 | 14346 |
| vLLM 0.32.0, AWQ | 8 | 80/80 | 0.066 ± 0.004 | 141.1 ± 0.7 | 0.521 ± 0.011 | 968.3 ± 16.8 | 14348 |
| vLLM 0.32.0, AWQ | 16 | 80/80 | 0.307 ± 0.010 | 139.3 ± 2.7 | 0.789 ± 0.033 | 974.0 ± 33.7 | 14348 |
| Ollama 0.40.13, defaults (1 slot) | 1 | 80/80 | 0.023 ± 0.005 | 137.3 ± 5.0 | 0.488 ± 0.021 | 129.1 ± 8.8 | 6100 |
| Ollama 0.40.13, defaults (1 slot) | 2 | 80/80 | 0.494 ± 0.011 | 138.3 ± 2.4 | 0.954 ± 0.017 | 131.3 ± 5.0 | 6102 |
| Ollama 0.40.13, defaults (1 slot) | 4 | 80/80 | 1.403 ± 0.023 | 140.2 ± 1.0 | 1.852 ± 0.022 | 134.3 ± 2.3 | 6101 |
| Ollama 0.40.13, defaults (1 slot) | 8 | 80/80 | 3.248 ± 0.013 | 141.0 ± 0.3 | 3.696 ± 0.025 | 135.9 ± 0.4 | 6102 |
| Ollama 0.40.13, defaults (1 slot) | 16 | 80/80 | 3.523 ± 0.197 | 140.7 ± 3.3 | 3.959 ± 0.209 | 134.9 ± 5.0 | 6114 |
| Ollama 0.40.13, tuned (8 slots) | 1 | 80/80 | 0.033 ± 0.006 | 113.0 ± 9.4 | 0.599 ± 0.051 | 104.1 ± 4.7 | 7812 |
| Ollama 0.40.13, tuned (8 slots) | 2 | 80/80 | 0.047 ± 0.009 | 104.0 ± 5.0 | 0.661 ± 0.032 | 172.3 ± 64.4 | 7819 |
| Ollama 0.40.13, tuned (8 slots) | 4 | 80/80 | 0.064 ± 0.010 | 89.5 ± 8.5 | 0.786 ± 0.070 | 325.9 ± 22.8 | 7812 |
| Ollama 0.40.13, tuned (8 slots) | 8 | 80/80 | 0.056 ± 0.012 | 70.7 ± 7.6 | 0.940 ± 0.092 | 520.2 ± 52.7 | 7813 |
| Ollama 0.40.13, tuned (8 slots) | 16 | 80/80 | 0.398 ± 0.058 | 76.7 ± 5.6 | 1.240 ± 0.066 | 564.4 ± 54.2 | 7813 |

Source: `results/phase3/vllm/, results/phase3/ollama-default/, results/phase3/ollama-tuned/`
<!-- END generated: repeated-runs -->

## Start-up

<!-- BEGIN generated: startup -->
| Case | Seconds |
|---|---|
| k3s, scale 0 to 1, weights already in PVC (3 runs) | 144.8, 134.6, 143.8 |
| Docker, weights already in volume (1 run) | 138.1 |
| Docker, empty volume: weights downloaded from Hugging Face (1 run) | 7302.2 |

Source: `results/startup/*.csv`
<!-- END generated: startup -->

## GPU time-slicing

<!-- BEGIN generated: sharing -->
| Setup | Concurrency | OK | TTFT p50 | Tok/s p50 | E2E p50 | E2E p95 |
|---|---|---|---|---|---|---|
| Pod A alone | 1 | 16/16 | 0.013 | 153.1 | 0.431 | 0.436 |
| Pod A alone | 4 | 16/16 | 0.024 | 155.9 | 0.434 | 0.437 |
| Pod A, with B also under load | 1 | 48/48 | 0.022 | 71.7 | 0.912 | 0.942 |
| Pod A, with B also under load | 4 | 48/48 | 0.049 | 72.8 | 0.928 | 0.938 |
| Pod B, with A also under load | 1 | 48/48 | 0.022 | 71.5 | 0.918 | 0.935 |
| Pod B, with A also under load | 4 | 48/48 | 0.051 | 71.2 | 0.946 | 0.975 |

Source: `results/sharing/a_alone/, results/sharing/a_with_b/, results/sharing/b_with_a/`
<!-- END generated: sharing -->
