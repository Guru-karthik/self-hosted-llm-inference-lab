# Sharing GPUs between Slurm batch work and a Kubernetes inference platform

**Status: design note. Apart from the two observations under "What the lab showed", every claim here is a design, not tested.**

## The problem

Batch training and research jobs (Slurm) want whole GPUs, can wait in a queue and care about throughput and fair-share. Online inference (Kubernetes) wants a GPU that is already loaded, answers in milliseconds and is often idle between requests. Both want the same hardware, and each scheduler assumes it owns what it schedules.

## What the lab showed

- On one machine, Slurm offered `gpu:1` while a k3s vLLM pod was already holding most of that GPU's memory. Neither scheduler knows about the other ([`results/slurm/gpu/`](../results/slurm/gpu/)).
- A Slurm job that did not ask for a GPU could still use `nvidia-smi` to see it: this sandbox enforces no device access.

Both come from a WSL2 sandbox with no device files to constrain. A Linux cluster with `/dev/nvidia*` and `ConstrainDevices=yes` behaves differently for the second point (design, not tested). The first point, two schedulers with no shared view, is what the options below address.

## Options

| Option | How it works (design, not tested) | Utilisation | Inference latency | Isolation | Operational cost |
|---|---|---|---|---|---|
| **A. Static split** | Some nodes run only `slurmd`, others only kubelet. Moving a node is a deliberate drain and re-join. | Lowest: idle inference GPUs cannot serve queued batch jobs, and the reverse. | Most predictable: models stay loaded. | Strongest: node-level. | Lowest. Two systems, clear ownership. |
| **B. Time-based split** | A calendar or controller drains Slurm nodes by day and hands them to Kubernetes, and back at night (Slurm reservations plus Kubernetes cordon/scale). | Better if demand really follows the clock. | A node joining inference pays a cold start first (this lab measured a little over 2 minutes with cached weights for one 7B model, see README). | Node-level, but hand-over must clean GPU and local disk. | Medium. The hand-over automation can fail half-way. |
| **C. Slinky (Slurm on Kubernetes)** | SchedMD's Slinky project runs Slurm daemons as Kubernetes workloads (slurm-operator), or lets Slurm schedule Kubernetes pods (slurm-bridge). One pool of nodes, one place that knows GPU allocation when the bridge is used. | Potentially high: capacity moves without re-installing nodes. | Depends on priorities and preemption: inference needs reserved capacity or a higher priority. | Weaker than A: shared kernel and nodes; pods and jobs need runtime isolation. | High. Two scheduling models to understand and upgrade together. |
| **D. Kueue (batch inside Kubernetes)** | Replace or complement Slurm for container-native batch: Kueue queues Kubernetes Jobs against quotas, with borrowing between queues and preemption. | High within one cluster. | Inference quota can be protected, borrowed capacity reclaimed by preemption; reclaim is not instant. | Namespaces, quotas, RBAC, NetworkPolicy; GPU memory isolation still needs MIG or whole GPUs. | Medium for Kubernetes teams; users of `sbatch` and MPI workflows must change habits. |

## What I would weigh first

1. **Who the users are.** Researchers with MPI and `sbatch` scripts make D hard to adopt on its own. Services with HTTP APIs do not fit plain Slurm well.
2. **Whether inference demand is predictable.** If not, B saves little and adds failure modes.
3. **Preemption tolerance.** Sharing only pays off if some batch work can be checkpointed and stopped.
4. **Isolation requirement.** Different tenants on one GPU through time-slicing is not isolation (shown in this lab's time-slicing experiment). Whole GPUs or MIG-capable hardware are needed for that.

My starting recommendation for a university site would be **A with a small, written rule for moving nodes**, then measure idle time for some weeks before adding B or C. This is a judgement from design reasoning, not a result.

## How to test this (not done)

One scheduler trace of batch jobs plus a synthetic inference load, replayed on each option; record GPU busy time, queue wait, inference TTFT p95, failed requests during hand-over, and what one tenant can see of another. This needs more than one GPU and more than one node.
