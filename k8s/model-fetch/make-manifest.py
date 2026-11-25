#!/usr/bin/env python3
"""Write a pinned manifest from the publisher's file listing (Hugging Face API).

    python k8s/model-fetch/make-manifest.py Qwen/Qwen2.5-7B-Instruct-AWQ <commit> out.json

Run by whoever reviews a model request, on a machine with internet access; the Job
never calls the API. Takes sha256 for large (LFS) files and the git blob SHA-1 for the
rest. .gitattributes is skipped (not part of the model).
"""
from __future__ import annotations

import json
import re
import sys
import urllib.request
from pathlib import Path


def manifest_from_tree(model: str, revision: str, tree: list[dict]) -> dict:
    files = []
    for item in tree:
        if item.get("type", "file") != "file" or item["path"] == ".gitattributes":
            continue
        lfs = item.get("lfs")
        files.append({"path": item["path"], "size": item["size"],
                      "algorithm": "sha256" if lfs else "git-sha1",
                      "digest": lfs["oid"] if lfs else item["oid"]})
    return {"model": model, "revision": revision, "files": files}


def main() -> int:
    model, revision, out = sys.argv[1:4]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        sys.exit("revision must be a full commit hash, not a branch or tag")
    url = f"https://huggingface.co/api/models/{model}/tree/{revision}"
    with urllib.request.urlopen(url, timeout=30) as response:
        manifest = manifest_from_tree(model, revision, json.load(response))
    Path(out).write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"{out}: {len(manifest['files'])} files, {sum(f['size'] for f in manifest['files'])} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
