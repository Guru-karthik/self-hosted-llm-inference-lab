"""Fetch a model into a volume, publishing it only if it passes every check.

    python fetch.py --manifest m.json --source file:///path/or/https://mirror/ \
        --dest /models --max-bytes 8000000000

The manifest pins a model revision and, for every file, its size and the publisher's
digest (sha256 for large files, git blob SHA-1 for the others). Checks:
  1. only allowed file types; weights must be .safetensors (no pickle formats);
  2. declared total size within --max-bytes, and no file may exceed its declared size;
  3. size and digest of every file match;
  4. each .safetensors file has a readable safetensors header;
  5. config.json must not ask for custom code (auto_map).
Files are written to a staging folder and moved into the Hugging Face cache layout only
after everything passed. These checks show the files are the pinned ones; they say
nothing about whether the model behaves well. Standard library only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import urllib.request
from pathlib import Path, PurePosixPath

ALLOWED_SUFFIXES = {".safetensors", ".json", ".txt", ".md"}
ALLOWED_NAMES = {"LICENSE", "NOTICE"}
CHUNK = 8 * 1024 * 1024


class Refused(Exception):
    """The model must not be published."""


def check_manifest(manifest: dict, max_bytes: int) -> None:
    files = manifest.get("files")
    if not files:
        raise Refused("manifest lists no files")
    for entry in files:
        path = PurePosixPath(entry["path"])
        if path.is_absolute() or ".." in path.parts or len(path.parts) != 1:
            raise Refused(f"unsafe path: {entry['path']}")
        if path.suffix not in ALLOWED_SUFFIXES and path.name not in ALLOWED_NAMES:
            raise Refused(f"file type not allowed (weights must be safetensors): {path}")
        if entry["algorithm"] not in ("sha256", "git-sha1"):
            raise Refused(f"unknown digest algorithm: {entry['algorithm']}")
    if not any(entry["path"].endswith(".safetensors") for entry in files):
        raise Refused("no safetensors weights in the manifest")
    total = sum(entry["size"] for entry in files)
    if total > max_bytes:
        raise Refused(f"model is {total} bytes, over the limit of {max_bytes}")


def download(url: str, target: Path, entry: dict) -> None:
    """Stream one file, hashing as it arrives; stop as soon as it is too long."""
    size = entry["size"]
    if entry["algorithm"] == "sha256":
        digest = hashlib.sha256()
    else:  # git's object id: SHA-1 over a header and the content
        digest = hashlib.sha1(f"blob {size}\0".encode())
    received = 0
    with urllib.request.urlopen(url, timeout=60) as response, target.open("wb") as out:
        while chunk := response.read(CHUNK):
            received += len(chunk)
            if received > size:
                raise Refused(f"{entry['path']}: larger than the declared {size} bytes")
            digest.update(chunk)
            out.write(chunk)
    if received != size:
        raise Refused(f"{entry['path']}: {received} bytes, expected {size}")
    if digest.hexdigest() != entry["digest"]:
        raise Refused(f"{entry['path']}: {entry['algorithm']} mismatch")


def check_safetensors(path: Path) -> None:
    with path.open("rb") as handle:
        length = int.from_bytes(handle.read(8), "little")
        if not 2 <= length <= min(path.stat().st_size - 8, 100 * 1024 * 1024):
            raise Refused(f"{path.name}: not a safetensors file")
        try:
            header = json.loads(handle.read(length))
        except ValueError as error:
            raise Refused(f"{path.name}: not a safetensors file") from error
    if not isinstance(header, dict):
        raise Refused(f"{path.name}: not a safetensors file")


def fetch(manifest: dict, source: str, dest: Path, max_bytes: int, log=print) -> Path:
    check_manifest(manifest, max_bytes)
    repo = dest / "hub" / ("models--" + manifest["model"].replace("/", "--"))
    snapshot = repo / "snapshots" / manifest["revision"]
    staging = dest / ".staging"
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    try:
        for entry in manifest["files"]:
            target = staging / entry["path"]
            download(source.rstrip("/") + "/" + entry["path"], target, entry)
            if target.suffix == ".safetensors":
                check_safetensors(target)
            if target.name == "config.json" and "auto_map" in json.loads(target.read_text()):
                raise Refused("config.json asks for custom code (auto_map)")
            log(f"verified {entry['path']} ({entry['size']} bytes, {entry['algorithm']})")
        shutil.rmtree(snapshot, ignore_errors=True)
        snapshot.parent.mkdir(parents=True, exist_ok=True)
        staging.rename(snapshot)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    (repo / "refs").mkdir(exist_ok=True)
    (repo / "refs" / "main").write_text(manifest["revision"])
    return snapshot


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--source", required=True, help="base URL holding the files")
    parser.add_argument("--dest", type=Path, required=True)
    parser.add_argument("--max-bytes", type=int, required=True)
    args = parser.parse_args(argv)
    manifest = json.loads(args.manifest.read_text())
    print(f"{manifest['model']} @ {manifest['revision']} from {args.source}")
    try:
        snapshot = fetch(manifest, args.source, args.dest, args.max_bytes,
                         log=lambda line: print(line, flush=True))
    except (Refused, OSError) as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 1
    print(f"published {snapshot}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
