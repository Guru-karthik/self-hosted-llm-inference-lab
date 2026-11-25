"""The evaluation server must plant the payload only where its case says."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import injected_server  # noqa: E402


def test_tool_result_case_appends_only_to_scrape_status(monkeypatch):
    monkeypatch.setattr(injected_server.base, "_fmt", lambda name, unit, window=None, **kw: "value")
    injected_server.install(injected_server.load_case("I3-tool-result-canary"))
    poisoned = injected_server.base._fmt
    assert "CANARY-7F3A" in poisoned("up", "", tool="vllm_scrape_up")
    assert poisoned("errors", "", tool="error_rate") == "value"
