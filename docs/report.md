<!-- Short technical report on the lab (Phase R). Tables between the markers are generated
     from results/ by scripts/render-results.py and checked in CI; do not edit them by hand. -->
# Serving a 7B model on one GPU: measurements, isolation and operations

*Technical report. Draft.*

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
