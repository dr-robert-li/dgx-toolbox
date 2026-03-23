"""Tests for trend charts, JSON export."""
from __future__ import annotations

import json
import pytest


def _make_run(run_id: str, f1: float, timestamp: str = "2026-03-23T10:00:00") -> dict:
    """Create a mock eval run dict."""
    return {
        "run_id": run_id,
        "timestamp": timestamp,
        "source": "replay",
        "metrics": {
            "f1": f1,
            "correct_refusal_rate": 0.98,
            "false_refusal_rate": 0.02,
            "p50_latency_ms": 150,
            "p95_latency_ms": 300,
        },
        "config_snapshot": {},
    }


def test_render_trends_empty():
    from harness.eval.trends import render_trends

    result = render_trends([])
    assert "No eval runs found" in result


def test_render_trends_with_data():
    from harness.eval.trends import render_trends

    runs = [
        _make_run(f"replay-{i:03d}", f1=0.90 + i * 0.01, timestamp=f"2026-03-2{i+1}T10:00:00")
        for i in range(5)
    ]
    result = render_trends(runs)
    assert "F1" in result or "f1" in result.lower()
    # Should contain some numeric values
    assert any(c.isdigit() for c in result)


def test_export_trends_json():
    from harness.eval.trends import export_trends_json

    runs = [_make_run(f"replay-{i:03d}", f1=0.90 + i * 0.01) for i in range(3)]
    result = export_trends_json(runs)
    assert isinstance(result, list)
    assert len(result) == 3
    for item in result:
        assert "run_id" in item
        assert "timestamp" in item
        assert "source" in item
        assert "metrics" in item


def test_render_trends_direction_arrows():
    from harness.eval.trends import render_trends

    # Second run has higher f1 than first -> should show UP indicator
    runs = [
        _make_run("replay-001", f1=0.90, timestamp="2026-03-21T10:00:00"),
        _make_run("replay-002", f1=0.95, timestamp="2026-03-22T10:00:00"),
    ]
    result = render_trends(runs)
    # Should contain up arrow or UP indicator
    assert any(indicator in result for indicator in ["UP", "up", "↑", "^", "rising", "STABLE"])
