"""Tests for CI gate regression detection and exit code logic."""
from __future__ import annotations

import pytest
from unittest.mock import AsyncMock, patch


# ---------------------------------------------------------------------------
# check_regression unit tests
# ---------------------------------------------------------------------------

def test_no_regression():
    from harness.eval.gate import check_regression

    # All metrics within tolerance: f1 up, refusal up, false_refusal down, latency within 2%
    current = {"f1": 0.92, "correct_refusal_rate": 0.95, "false_refusal_rate": 0.03, "p95_latency_ms": 404}
    baseline = {"f1": 0.90, "correct_refusal_rate": 0.93, "false_refusal_rate": 0.05, "p95_latency_ms": 400}
    regressed, failures = check_regression(current, baseline)
    assert not regressed
    assert failures == []


def test_f1_regression():
    from harness.eval.gate import check_regression

    current = {"f1": 0.80}
    baseline = {"f1": 0.90}
    # f1 dropped by 0.10, tolerance is 0.02 -> regression
    regressed, failures = check_regression(current, baseline, safety_tolerance=0.02)
    assert regressed
    assert len(failures) == 1
    assert "f1" in failures[0]


def test_false_refusal_regression():
    from harness.eval.gate import check_regression

    current = {"false_refusal_rate": 0.15}
    baseline = {"false_refusal_rate": 0.05}
    # false_refusal_rate rose by 0.10, tolerance is 0.02 -> regression
    regressed, failures = check_regression(current, baseline, safety_tolerance=0.02)
    assert regressed
    assert any("false_refusal_rate" in f for f in failures)


def test_latency_regression():
    from harness.eval.gate import check_regression

    current = {"p95_latency_ms": 2000}
    baseline = {"p95_latency_ms": 1000}
    # 2000 > 1000 * (1 + 0.02) -> regression
    regressed, failures = check_regression(current, baseline, safety_tolerance=0.02)
    assert regressed
    assert any("p95_latency_ms" in f for f in failures)


def test_missing_baseline_key_skipped():
    from harness.eval.gate import check_regression

    # current has a key that baseline doesn't have -> skip that key
    current = {"f1": 0.90, "new_metric": 0.50}
    baseline = {"f1": 0.90}
    regressed, failures = check_regression(current, baseline)
    assert not regressed
    assert failures == []


def test_capability_tolerance_separate():
    from harness.eval.gate import check_regression

    # mmlu = 0.55, baseline = 0.60, capability_tolerance = 0.05 -> within tolerance (0.60 - 0.55 = 0.05, NOT > 0.05)
    current = {"mmlu": 0.55}
    baseline = {"mmlu": 0.60}
    regressed, failures = check_regression(current, baseline, capability_tolerance=0.05)
    assert not regressed

    # mmlu = 0.54, baseline = 0.60, capability_tolerance = 0.05 -> regression (0.60 - 0.54 = 0.06 > 0.05)
    current2 = {"mmlu": 0.54}
    regressed2, failures2 = check_regression(current2, baseline, capability_tolerance=0.05)
    assert regressed2


def test_gate_exit_code_pass():
    """run_gate returns 0 when metrics are within tolerance."""
    from harness.eval import gate

    replay_result = {
        "run_id": "replay-abc",
        "metrics": {"f1": 0.92, "p95_latency_ms": 285},
        "per_case_results": [],
        "total_cases": 10,
    }
    baseline_run = {
        "run_id": "replay-old",
        "timestamp": "2026-01-01T00:00:00",
        "source": "replay",
        "metrics": {"f1": 0.90, "p95_latency_ms": 280},
        "config_snapshot": {},
        "baseline_name": None,
    }

    with patch("harness.eval.gate.run_replay", new_callable=AsyncMock) as mock_replay, \
         patch("harness.eval.gate.TraceStore") as MockStore:
        mock_replay.return_value = replay_result
        mock_store = AsyncMock()
        mock_store.query_eval_runs = AsyncMock(return_value=[replay_result, baseline_run])
        MockStore.return_value = mock_store

        import asyncio
        exit_code = asyncio.run(gate.run_gate(
            dataset_path="dummy.jsonl",
            gateway_base_url="http://localhost:8080",
            api_key="sk-test",
            db_path=":memory:",
        ))
    assert exit_code == 0


def test_gate_exit_code_regression():
    """run_gate returns 1 when regression detected."""
    from harness.eval import gate

    replay_result = {
        "run_id": "replay-abc",
        "metrics": {"f1": 0.70, "p95_latency_ms": 300},
        "per_case_results": [],
        "total_cases": 10,
    }
    baseline_run = {
        "run_id": "replay-old",
        "timestamp": "2026-01-01T00:00:00",
        "source": "replay",
        "metrics": {"f1": 0.90, "p95_latency_ms": 280},
        "config_snapshot": {},
        "baseline_name": None,
    }

    with patch("harness.eval.gate.run_replay", new_callable=AsyncMock) as mock_replay, \
         patch("harness.eval.gate.TraceStore") as MockStore:
        mock_replay.return_value = replay_result
        mock_store = AsyncMock()
        mock_store.query_eval_runs = AsyncMock(return_value=[replay_result, baseline_run])
        MockStore.return_value = mock_store

        import asyncio
        exit_code = asyncio.run(gate.run_gate(
            dataset_path="dummy.jsonl",
            gateway_base_url="http://localhost:8080",
            api_key="sk-test",
            db_path=":memory:",
        ))
    assert exit_code == 1


def test_gate_exit_code_eval_error():
    """run_gate returns 2 when eval raises an exception."""
    from harness.eval import gate

    with patch("harness.eval.gate.run_replay", new_callable=AsyncMock) as mock_replay, \
         patch("harness.eval.gate.TraceStore") as MockStore:
        mock_replay.side_effect = RuntimeError("connection refused")
        mock_store = AsyncMock()
        MockStore.return_value = mock_store

        import asyncio
        exit_code = asyncio.run(gate.run_gate(
            dataset_path="dummy.jsonl",
            gateway_base_url="http://localhost:8080",
            api_key="sk-test",
            db_path=":memory:",
        ))
    assert exit_code == 2
