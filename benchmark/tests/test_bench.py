import pytest

from benchmark.bench import (
    across_runs,
    aggregate_throughput,
    consume_stream,
    nearest_rank_percentile,
    parse_sse_data,
    summarize_level,
    summarize_requests,
)


def test_parse_sse_data_ignores_non_data_lines_and_stops_at_done():
    lines = [
        "event: message",
        "",
        'data: {"choices":[{"delta":{"content":"hi"}}]}',
        "data: [DONE]",
        'data: {"choices":[{"delta":{"content":"ignored"}}]}',
    ]

    assert list(parse_sse_data(lines)) == [
        {"choices": [{"delta": {"content": "hi"}}]}
    ]


def test_consume_stream_reads_first_content_and_completion_usage(monkeypatch):
    monkeypatch.setattr("benchmark.bench.time.monotonic", lambda: 5.25)
    lines = [
        'data: {"choices":[{"delta":{"role":"assistant"}}]}',
        'data: {"choices":[{"delta":{"content":"hello"}}]}',
        'data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":4}}',
        "data: [DONE]",
    ]

    assert consume_stream(lines, request_started=5.0) == (0.25, 4)


def test_consume_stream_allows_missing_usage():
    lines = ['data: {"choices":[{"delta":{"content":"hello"}}]}', "data: [DONE]"]

    ttft, completion_tokens = consume_stream(lines, request_started=0.0)

    assert ttft is not None
    assert completion_tokens is None


def test_parse_sse_data_rejects_non_object_payload():
    with pytest.raises(ValueError, match="JSON object"):
        list(parse_sse_data(["data: []"]))


def test_nearest_rank_percentile_uses_nearest_rank():
    assert nearest_rank_percentile([5.0, 1.0, 4.0, 2.0, 3.0], 0.95) == 5.0
    assert nearest_rank_percentile([], 0.95) is None


def test_nearest_rank_percentile_rejects_invalid_percentile():
    with pytest.raises(ValueError, match="percentile"):
        nearest_rank_percentile([1.0], 0)


def test_summary_reports_failures_and_successful_latency_statistics():
    records = [
        {
            "success": True,
            "ttft_seconds": 0.2,
            "end_to_end_seconds": 1.2,
            "completion_tokens": 10,
            "tokens_per_second": 10.0,
        },
        {
            "success": True,
            "ttft_seconds": 0.4,
            "end_to_end_seconds": 1.8,
            "completion_tokens": None,
            "tokens_per_second": None,
        },
        {
            "success": False,
            "ttft_seconds": None,
            "end_to_end_seconds": 0.1,
            "completion_tokens": None,
            "tokens_per_second": None,
        },
    ]

    summary = summarize_requests(records, concurrency=2, peak_vram_mib=9000)

    assert summary["request_count"] == 3
    assert summary["success_count"] == 2
    assert summary["failure_count"] == 1
    assert summary["failure_rate"] == pytest.approx(1 / 3)
    assert summary["ttft_p50_seconds"] == pytest.approx(0.3)
    assert summary["end_to_end_p50_seconds"] == pytest.approx(1.5)
    assert summary["tokens_per_second_p50"] == 10.0
    assert summary["token_count_unavailable_count"] == 1
    assert summary["peak_vram_mib"] == 9000


def _record(ttft, e2e, tokens, success=True):
    return {
        "success": success,
        "ttft_seconds": ttft,
        "end_to_end_seconds": e2e,
        "completion_tokens": tokens,
        "tokens_per_second": 100.0 if success else None,
    }


def test_across_runs_uses_sample_std_and_t_interval():
    result = across_runs([1.0, 2.0, 3.0, 4.0, 5.0])

    assert result["n"] == 5
    assert result["mean"] == pytest.approx(3.0)
    assert result["std"] == pytest.approx(1.5811388)
    # t(0.975, df=4) = 2.776; half width = 2.776 * 1.5811388 / sqrt(5)
    assert result["ci95_high"] - result["mean"] == pytest.approx(1.962918, rel=1e-5)
    assert result["mean"] - result["ci95_low"] == pytest.approx(1.962918, rel=1e-5)


def test_across_runs_gives_no_interval_for_a_single_run():
    result = across_runs([2.0, None])

    assert result["n"] == 1
    assert result["mean"] == 2.0
    assert result["std"] is None and result["ci95_low"] is None
    assert across_runs([])["mean"] is None


def test_aggregate_throughput_counts_successful_tokens_over_wall_time():
    records = [_record(0.1, 1.0, 60), _record(0.1, 1.0, 40), _record(None, 0.1, None, False)]

    assert aggregate_throughput(records, 4.0) == pytest.approx(25.0)
    assert aggregate_throughput(records + [_record(0.1, 1.0, None)], 4.0) is None


def test_summarize_level_pools_requests_and_compares_runs():
    runs = [[_record(0.1, 1.0, 10)], [_record(0.3, 3.0, 10)]]

    summary = summarize_level(runs, wall_seconds=[1.0, 2.0], peak_vram_mib=[100, 120], concurrency=4)

    assert summary["request_count"] == 2 and summary["runs"] == 2
    assert summary["peak_vram_mib"] == 120
    assert summary["across_runs"]["ttft_p50_seconds"]["mean"] == pytest.approx(0.2)
    assert summary["across_runs"]["aggregate_output_tokens_per_second"]["mean"] == pytest.approx(7.5)
    assert [run["run"] for run in summary["run_summaries"]] == [1, 2]
