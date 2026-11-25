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


def test_readme_tables_match_the_result_files():
    readme = (ROOT / "README.md").read_text()
    for name, build in render_results.TABLES.items():
        assert render_results.render(readme, name, build()) == readme, f"table {name} is out of date"
