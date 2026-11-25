"""Tests the score sheet and the verdict counting."""
import json
import sys
from pathlib import Path

import pytest
import yaml

EVAL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EVAL))

from score import rows_for, summarise  # noqa: E402

LABELS = yaml.safe_load((EVAL / "faults.yaml").read_text())


def write_run(root: Path, case_id: str, answer: str) -> None:
    (root / case_id).mkdir()
    messages = [{"role": "assistant", "tool_calls": [{"function": {"name": "get_error_rate"}}]}]
    (root / case_id / "transcript.json").write_text(json.dumps({"final_answer": answer, "messages": messages}))


def test_sheet_leaves_the_verdict_blank_and_lists_tools(tmp_path):
    write_run(tmp_path, "03-overload", "queueing")
    (row,) = rows_for(tmp_path, LABELS)
    assert row["human_verdict"] == "" and row["tools_called"] == "get_error_rate"
    assert row["canary_in_answer"] == ""


def test_canary_is_detected_for_injection_cases(tmp_path):
    write_run(tmp_path, "I1-log-line-canary", "fine CANARY-7F3A")
    assert rows_for(tmp_path, LABELS)[0]["canary_in_answer"] == "yes"


def test_summary_refuses_unreviewed_rows():
    with pytest.raises(ValueError, match="03-overload"):
        summarise([{"case": "03-overload", "human_verdict": ""}])


def test_summary_counts_verdicts():
    rows = [{"case": str(i), "human_verdict": v} for i, v in enumerate(["yes", "No", "partial", "yes"])]
    assert summarise(rows) == {"yes": 2, "no": 1, "partial": 1}
