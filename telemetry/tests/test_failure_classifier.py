"""Tests for failure_classifier module (TELEM-13, TELEM-14)."""

import pytest
from telemetry.failure_classifier import classify_failure


def test_clean_exit():
    """Training completed with exit_code=0 returns clean classification."""
    result = classify_failure(
        {"mem_available_gb": 50.0, "gpu_util_pct": 80, "cpu_pct": 40, "temperature_c": 60, "duration_at_state_s": 0},
        exit_code=0,
        training_completed=True,
    )
    assert result["classification"] == "clean"
    assert result["evidence"] == {}


def test_oom():
    """GPU idle + near-zero memory => oom classification with evidence."""
    result = classify_failure(
        {"mem_available_gb": 0.5, "gpu_util_pct": 3, "cpu_pct": 20, "temperature_c": 70, "duration_at_state_s": 10},
        exit_code=1,
        training_completed=False,
    )
    assert result["classification"] == "oom"
    assert "mem_available_gb" in result["evidence"]
    assert "gpu_util_pct" in result["evidence"]


def test_hang():
    """GPU idle + CPU saturated + 120s duration + healthy memory => hang classification."""
    result = classify_failure(
        {"mem_available_gb": 40.0, "gpu_util_pct": 2, "cpu_pct": 95, "temperature_c": 55, "duration_at_state_s": 120},
        exit_code=1,
        training_completed=False,
    )
    assert result["classification"] == "hang"
    assert "evidence" in result


def test_thermal():
    """High temperature => thermal classification."""
    result = classify_failure(
        {"mem_available_gb": 30.0, "gpu_util_pct": 80, "cpu_pct": 60, "temperature_c": 90, "duration_at_state_s": 30},
        exit_code=1,
        training_completed=False,
    )
    assert result["classification"] == "thermal"


def test_pressure():
    """Low memory (but not full OOM) => pressure classification."""
    result = classify_failure(
        {"mem_available_gb": 2.0, "gpu_util_pct": 70, "cpu_pct": 50, "temperature_c": 70, "duration_at_state_s": 5},
        exit_code=1,
        training_completed=False,
    )
    assert result["classification"] == "pressure"


def test_hang_no_batch_cap():
    """HANG classification must NEVER contain batch_cap key (TELEM-14)."""
    result = classify_failure(
        {"mem_available_gb": 40.0, "gpu_util_pct": 2, "cpu_pct": 95, "temperature_c": 55, "duration_at_state_s": 120},
        exit_code=1,
        training_completed=False,
    )
    assert result["classification"] == "hang"
    assert "batch_cap" not in result
    # Also verify the evidence dict doesn't contain batch_cap
    assert "batch_cap" not in result.get("evidence", {})


def test_unknown_defaults_clean():
    """Borderline values that match no specific pattern return clean."""
    result = classify_failure(
        {"mem_available_gb": 20.0, "gpu_util_pct": 50, "cpu_pct": 50, "temperature_c": 65, "duration_at_state_s": 5},
        exit_code=1,
        training_completed=False,
    )
    assert result["classification"] == "clean"
