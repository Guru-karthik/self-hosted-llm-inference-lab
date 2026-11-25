#!/usr/bin/env bash
# Apptainer on WSL2: run the benchmark client from a .sif against the running vLLM, and
# check CUDA compute access from inside a container. No sudo. Run from anywhere:
#     slurm/apptainer/run-apptainer-test.sh /path/for/bench-client.sif
# WSL2 has no /dev/nvidia*; `--nv` alone failed here (results/slurm/apptainer/
# gpu_visibility.txt), so the WSL driver folder is bound in by hand.
set -euo pipefail
cd "$(dirname "$0")/../.."
SIF=${1:?usage: run-apptainer-test.sh /path/to/bench-client.sif}
OUT=results/slurm/apptainer
[ -f "$SIF" ] || apptainer build "$SIF" slurm/apptainer/bench-client.def

WSL=(--bind /usr/lib/wsl --env LD_LIBRARY_PATH=/usr/lib/wsl/lib
  --env APPEND_PATH=/usr/lib/wsl/lib)

# CUDA compute (not just nvidia-smi): initialise the driver, make a context, allocate 1 MiB.
apptainer exec "${WSL[@]}" "$SIF" python - <<'PY' 2>&1 | tee "$OUT/cuda_check.txt"
import ctypes as c
cuda = c.CDLL("libcuda.so.1")
def check(name, rc):
    print(f"{name}: rc={rc}")
    if rc:
        raise SystemExit(1)
check("cuInit", cuda.cuInit(0))
dev, ctx, ptr = c.c_int(), c.c_void_p(), c.c_uint64()
check("cuDeviceGet", cuda.cuDeviceGet(c.byref(dev), 0))
name = c.create_string_buffer(100)
check("cuDeviceGetName", cuda.cuDeviceGetName(name, 100, dev))
print("device:", name.value.decode())
check("cuCtxCreate_v2", cuda.cuCtxCreate_v2(c.byref(ctx), 0, dev))
check("cuMemAlloc_v2 (1 MiB)", cuda.cuMemAlloc_v2(c.byref(ptr), c.c_size_t(1 << 20)))
check("cuMemFree_v2", cuda.cuMemFree_v2(ptr))
check("cuCtxDestroy_v2", cuda.cuCtxDestroy_v2(ctx))
PY

ip="$(KUBECONFIG=$HOME/.kube/config k3s kubectl -n llm-inference get svc vllm -o jsonpath='{.spec.clusterIP}')"
apptainer run "${WSL[@]}" --bind "$PWD/$OUT:/out" "$SIF" --engine vllm \
  --software-version "0.32.0 (k3s, ClusterIP, Apptainer client)" \
  --image vllm/vllm-openai@sha256:befccf0e7e4089aa23926bb6f887a85c0d46c2a99e6de5c5ffdf5cb7957c5b34 \
  --base-url "http://$ip:8000/v1" --model qwen2.5-7b-awq --output-dir /out/bench \
  2>&1 | tee "$OUT/client_run.txt"
