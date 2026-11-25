"""Every labelled fault has a script, and the load generator builds what the labels say."""
import sys
from pathlib import Path

import yaml

EVAL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EVAL))

from loadgen import build_body  # noqa: E402

LABELS = yaml.safe_load((EVAL / "faults.yaml").read_text())


def test_every_label_has_exactly_one_script():
    scripts = sorted(path.stem for path in (EVAL / "faults").glob("[0-9]*.sh"))
    assert [fault["id"] for fault in LABELS["faults"]] == scripts


def test_labels_are_complete():
    for fault in LABELS["faults"]:
        assert {"expected", "correct_if", "partial_if", "injection", "settle_seconds"} <= set(fault)


def test_prompts_differ_so_prefix_cache_cannot_share_them():
    first = build_body("m", 10, 5, False)["messages"][0]["content"]
    second = build_body("m", 10, 5, False)["messages"][0]["content"]
    assert first != second


def test_long_prompt_and_ignore_eos():
    body = build_body("m", 2800, 600, True)
    assert body["messages"][0]["content"].split().count("alpha") == 2800
    assert body["ignore_eos"] is True and body["max_tokens"] == 600
