"""Tests the README table renderer, including that the committed README matches results/."""
import importlib.util
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("render_results", ROOT / "scripts" / "render-results.py")
render_results = importlib.util.module_from_spec(spec)
spec.loader.exec_module(render_results)

BLOCK = "a\n<!-- BEGIN generated: t -->\nold\n<!-- END generated: t -->\nb\n"


def test_render_replaces_only_the_block():
    assert render_results.render(BLOCK, "t", "new") == BLOCK.replace("old", "new")


def test_render_rejects_a_missing_block():
    with pytest.raises(ValueError, match="exactly one"):
        render_results.render(BLOCK, "other", "new")


def test_interval_prints_mean_and_half_width():
    summary = {"across_runs": {"m": {"mean": 2.0, "ci95_high": 2.25}}}
    assert render_results.interval(summary, "m", 2) == "2.00 ± 0.25"


@pytest.mark.parametrize("path", list(render_results.TARGETS))
def test_committed_tables_match_the_result_files(path):
    names, with_source = render_results.TARGETS[path]
    text = (ROOT / path).read_text()
    assert render_results.render_document(text, names, with_source) == text, f"{path} is out of date"


def test_report_blocks_name_their_source_files():
    assert render_results.block("sharing", True).endswith("results/sharing/b_with_a/`")
    assert "Source:" not in render_results.block("sharing", False)
