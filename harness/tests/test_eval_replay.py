"""Tests for eval metrics — covers compute_metrics and compute_latency_percentiles."""
import pytest
from harness.eval.metrics import compute_metrics, compute_latency_percentiles


def _make_case(expected_action: str, category: str = "injection") -> dict:
    return {
        "prompt": f"test prompt for {category}",
        "expected_action": expected_action,
        "category": category,
        "description": f"Test case for {category}",
    }


def _make_result(actual_action: str, latency_ms: int = 50, status_code: int = 200) -> dict:
    return {
        "actual_action": actual_action,
        "latency_ms": latency_ms,
        "status_code": status_code,
    }


def test_all_correct_blocks():
    """5 cases all expected='block', all actual='block' -> f1=1.0, correct_refusal_rate=1.0, false_refusal_rate=0.0"""
    cases = [_make_case("block") for _ in range(5)]
    results = [_make_result("block") for _ in range(5)]
    metrics = compute_metrics(cases, results)
    assert metrics["f1"] == 1.0
    assert metrics["correct_refusal_rate"] == 1.0
    assert metrics["false_refusal_rate"] == 0.0
    assert metrics["precision"] == 1.0
    assert metrics["recall"] == 1.0
    assert metrics["total_cases"] == 5


def test_all_correct_allows():
    """5 cases all expected='allow', all actual='allow' -> f1=0.0 (no positives), false_refusal_rate=0.0"""
    cases = [_make_case("allow", category="benign") for _ in range(5)]
    results = [_make_result("allow", status_code=200) for _ in range(5)]
    metrics = compute_metrics(cases, results)
    assert metrics["f1"] == 0.0
    assert metrics["false_refusal_rate"] == 0.0
    assert metrics["total_cases"] == 5


def test_mixed_results():
    """Mix of correct/incorrect blocks and allows — verify F1 matches hand-calculated value."""
    # tp=2, fp=1, tn=1, fn=1 -> precision=2/3, recall=2/3, f1=2/3 ≈ 0.6667
    cases = [
        _make_case("block"),  # tp: expected block, actual block
        _make_case("block"),  # tp: expected block, actual block
        _make_case("block"),  # fn: expected block, actual allow
        _make_case("allow", category="benign"),  # fp: expected allow, actual block
        _make_case("allow", category="benign"),  # tn: expected allow, actual allow
    ]
    results = [
        _make_result("block"),   # tp
        _make_result("block"),   # tp
        _make_result("allow"),   # fn
        _make_result("block"),   # fp
        _make_result("allow"),   # tn
    ]
    metrics = compute_metrics(cases, results)
    # precision = tp/(tp+fp) = 2/3, recall = tp/(tp+fn) = 2/3
    expected_precision = round(2 / 3, 4)
    expected_recall = round(2 / 3, 4)
    expected_f1 = round(2 * expected_precision * expected_recall / (expected_precision + expected_recall), 4)
    assert metrics["precision"] == expected_precision
    assert metrics["recall"] == expected_recall
    assert metrics["f1"] == expected_f1
    assert metrics["total_cases"] == 5


def test_steer_treated_as_block():
    """expected_action='steer' + actual='block' -> counted as tp."""
    cases = [_make_case("steer", category="injection")]
    results = [_make_result("block")]
    metrics = compute_metrics(cases, results)
    assert metrics["f1"] == 1.0
    assert metrics["correct_refusal_rate"] == 1.0
    assert metrics["precision"] == 1.0
    assert metrics["recall"] == 1.0


def test_per_category_breakdown():
    """2 categories — verify per_category dict has both keys with correct counts."""
    cases = [
        _make_case("block", category="injection"),
        _make_case("block", category="injection"),
        _make_case("allow", category="benign"),
        _make_case("allow", category="benign"),
    ]
    results = [
        _make_result("block"),   # injection tp
        _make_result("allow"),   # injection fn
        _make_result("allow"),   # benign tn
        _make_result("block"),   # benign fp
    ]
    metrics = compute_metrics(cases, results)
    assert "injection" in metrics["per_category"]
    assert "benign" in metrics["per_category"]
    inj = metrics["per_category"]["injection"]
    ben = metrics["per_category"]["benign"]
    assert inj["tp"] == 1
    assert inj["fn"] == 1
    assert ben["tn"] == 1
    assert ben["fp"] == 1


def test_latency_percentiles():
    """Known list -> verify p50 and p95."""
    latencies = [100, 200, 300, 400, 500]
    result = compute_latency_percentiles(latencies)
    assert result["p50"] == 300
    assert result["p95"] == 500


def test_latency_percentiles_empty():
    """Empty list -> p50=0, p95=0."""
    result = compute_latency_percentiles([])
    assert result["p50"] == 0
    assert result["p95"] == 0
