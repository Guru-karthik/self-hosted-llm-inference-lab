"""Tests the verification logic of fetch.py with tiny files served over file://."""
import hashlib
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from fetch import Refused, fetch, main  # noqa: E402

HEADER = json.dumps({"w": {"dtype": "F32", "shape": [1], "data_offsets": [0, 4]}}).encode()
WEIGHTS = len(HEADER).to_bytes(8, "little") + HEADER + b"\0\0\0\0"
CONFIG = b'{"model_type": "tiny"}'


def entry(name, content, algorithm="sha256"):
    if algorithm == "sha256":
        digest = hashlib.sha256(content).hexdigest()
    else:
        digest = hashlib.sha1(b"blob %d\0" % len(content) + content).hexdigest()
    return {"path": name, "size": len(content), "algorithm": algorithm, "digest": digest}


@pytest.fixture()
def model(tmp_path):
    source = tmp_path / "source"
    source.mkdir()
    (source / "model.safetensors").write_bytes(WEIGHTS)
    (source / "config.json").write_bytes(CONFIG)
    manifest = {"model": "org/tiny", "revision": "abc",
                "files": [entry("model.safetensors", WEIGHTS), entry("config.json", CONFIG, "git-sha1")]}
    return manifest, source, tmp_path / "dest"


def run(model, max_bytes=10_000):
    manifest, source, dest = model
    return fetch(manifest, source.as_uri(), dest, max_bytes, log=lambda line: None)


def assert_refused(model, message, max_bytes=10_000):
    with pytest.raises(Refused, match=message):
        run(model, max_bytes)
    dest = model[2]
    assert not (dest / "hub").exists() and not (dest / ".staging").exists()


def test_good_model_is_published_in_hub_layout(model):
    snapshot = run(model)
    assert (snapshot / "model.safetensors").read_bytes() == WEIGHTS
    assert (snapshot.parents[1] / "refs" / "main").read_text() == "abc"


def test_changed_content_of_same_size_is_refused(model):
    (model[1] / "model.safetensors").write_bytes(WEIGHTS[:-1] + b"\1")
    assert_refused(model, "sha256 mismatch")


def test_git_blob_digest_is_checked_for_small_files(model):
    (model[1] / "config.json").write_bytes(CONFIG.replace(b"tiny", b"tinz"))
    assert_refused(model, "git-sha1 mismatch")


@pytest.mark.parametrize("content, message", [(WEIGHTS + b"x", "larger than"), (WEIGHTS[:-1], "expected")])
def test_wrong_length_is_refused(model, content, message):
    (model[1] / "model.safetensors").write_bytes(content)
    assert_refused(model, message)


def test_total_size_limit(model):
    assert_refused(model, "over the limit", max_bytes=10)


@pytest.mark.parametrize("name", ["pytorch_model.bin", "weights.pt", "model.gguf", "modeling_x.py"])
def test_other_weight_formats_and_code_are_refused(model, name):
    model[0]["files"].append(entry(name, b"x"))
    assert_refused(model, "not allowed")


@pytest.mark.parametrize("name", ["../escape.json", "/etc/x.json", "sub/x.json"])
def test_unsafe_paths_are_refused(model, name):
    model[0]["files"].append(entry(name, b"{}"))
    assert_refused(model, "unsafe path")


def test_pickle_renamed_to_safetensors_is_refused(model):
    fake = b"\x80\x04" + b"pickle" * 10
    (model[1] / "model.safetensors").write_bytes(fake)
    model[0]["files"][0] = entry("model.safetensors", fake)
    assert_refused(model, "not a safetensors file")


def test_custom_code_request_is_refused(model):
    config = b'{"auto_map": {"AutoModel": "x.Y"}}'
    (model[1] / "config.json").write_bytes(config)
    model[0]["files"][1] = entry("config.json", config)
    assert_refused(model, "auto_map")


def test_command_line_exits_nonzero_when_refused(model, tmp_path, capsys):
    manifest, source, dest = model
    path = tmp_path / "m.json"
    path.write_text(json.dumps(manifest))
    code = main(["--manifest", str(path), "--source", source.as_uri(), "--dest", str(dest), "--max-bytes", "1"])
    assert code == 1 and "REFUSED" in capsys.readouterr().err
