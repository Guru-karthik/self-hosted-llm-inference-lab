"""Tests the transcript file that mcp/agent.py writes for the evaluation."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from agent import save_transcript  # noqa: E402

TOOLS = [{"type": "function", "function": {"name": "get_error_rate"}}]


def test_finished_run_records_the_final_answer(tmp_path):
    path = tmp_path / "t.json"
    save_transcript(str(path), [{"role": "assistant", "content": "healthy"}], TOOLS, finished=True)
    record = json.loads(path.read_text())
    assert record["final_answer"] == "healthy"
    assert record["tools_offered"] == ["get_error_rate"]


def test_unfinished_run_has_no_final_answer(tmp_path):
    path = tmp_path / "t.json"
    save_transcript(str(path), [{"role": "tool", "content": "1"}], TOOLS, finished=False)
    record = json.loads(path.read_text())
    assert record["finished"] is False and record["final_answer"] is None


def test_no_path_writes_nothing(tmp_path):
    save_transcript(None, [], TOOLS, finished=True)
    assert list(tmp_path.iterdir()) == []
