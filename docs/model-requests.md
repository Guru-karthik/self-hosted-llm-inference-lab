# How a tenant would request a model

What exists is one Job that was run for one model, by the cluster admin, in the `llm-inference` namespace, copying from a `file://` source ([`k8s/model-fetch/`](../k8s/model-fetch/)). **The request process below is a design. No tenant has used it, and it has not been tried in a tenant namespace.**

## What the tenant submits

A pull request adding `k8s/model-fetch/manifests/<name>.json`, made with [`make-manifest.py`](../k8s/model-fetch/make-manifest.py) from a **full commit hash** (not a branch or tag), plus:

- what the model is for, and who is responsible for it;
- its licence and any use restrictions;
- the size, and the serving memory they expect to need.

## Checks the Job applies (implemented and tested)

| Check | Refuses |
|---|---|
| Allowed file types | anything but `.safetensors`, `.json`, `.txt`, `.md`, `LICENSE`, `NOTICE`; so no pickle weights (`.bin`, `.pt`), no GGUF, no Python code |
| Paths | absolute paths, `..`, subfolders |
| Total size | a model over `--max-bytes` (set per tenant), before anything is copied |
| Per-file size | a file longer or shorter than declared |
| Digest | any file whose SHA-256 or git blob SHA-1 differs from the manifest |
| safetensors header | a file that is only renamed to `.safetensors` |
| Custom code | a `config.json` with `auto_map` |
| Publication | anything, unless every check passed (files go to a staging folder first) |

Unit tests cover each refusal. In the cluster, the real model passed and three altered runs (wrong digest in the manifest, size limit, a `.bin` entry) were refused ([`results/model-fetch/`](../results/model-fetch/)).

## Checks a person must do (not automated)

- Is the publisher who they say they are, and is the revision the intended one? The manifest records what the publisher listed when it was made; **the reviewer must make or re-make it themselves**, not trust the tenant's copy.
- Licence, data-protection and acceptable-use review.
- Does the model fit the tenant's quota and GPU?

## What these checks do not show

Matching digests mean the files are the pinned ones, not that the model is safe or behaves well. safetensors avoids code execution on load through pickle; it says nothing about backdoored behaviour, harmful output or flaws in the loader. `tokenizer` and template files are checked for integrity only.

## Missing for real use

- A source. Pods here could not download from Hugging Face ([write-up](pod-network-download-issue.md)). The code accepts `https://` URLs through Python's standard library, but **only `file://` has been run**. A site would more likely keep an internal mirror.
- Running it per tenant: tenant namespaces deny egress and allow one volume claim, so both would need a deliberate exception or a fetch service that writes for them.
- Signature verification, vulnerability scanning of the serving image, and an audit trail beyond Job logs.
