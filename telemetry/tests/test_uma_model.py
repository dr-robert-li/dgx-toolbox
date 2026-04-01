"""Tests for UMAMemModel (TELEM-05, TELEM-06)."""

import logging
import pytest
from pathlib import Path
from unittest.mock import patch, MagicMock
import sys


def _make_sampler_with_mock_meminfo(mock_pynvml_fixture, mock_meminfo_path):
    """Helper: import GPUSampler with _MEMINFO_PATH patched to the mock file.

    Returns (sampler, patch_context) — caller must manage cleanup via
    the module cache deletion after use.
    """
    # Ensure a clean module load so pynvml patching takes effect
    for mod_name in list(sys.modules.keys()):
        if mod_name.startswith("telemetry.sampler") or mod_name == "telemetry.sampler":
            del sys.modules[mod_name]

    import telemetry.sampler as sampler_module
    sampler_module._MEMINFO_PATH = mock_meminfo_path
    from telemetry.sampler import GPUSampler
    return GPUSampler(), sampler_module


def test_sample_baseline(mock_pynvml, mock_meminfo):
    """sample_baseline() returns dict with required keys; mem_available_gb == 80.0 in mock mode."""
    sampler, sampler_module = _make_sampler_with_mock_meminfo(mock_pynvml, mock_meminfo)
    try:
        from telemetry.uma_model import UMAMemModel

        model = UMAMemModel(sampler)
        baseline = model.sample_baseline()

        assert "mem_available_gb" in baseline
        assert "page_cache_gb" in baseline
        assert "idle_watts" in baseline
        assert "timestamp" in baseline
        # mock_pynvml forces mock mode -> mem_available_gb comes from mock_meminfo -> 80.0
        assert abs(baseline["mem_available_gb"] - 80.0) < 0.01, (
            f"Expected ~80.0 GB, got {baseline['mem_available_gb']}"
        )
        # mock mode: idle_watts == 0.0
        assert baseline["idle_watts"] == 0.0
    finally:
        # Restore module state so downstream tests aren't affected
        if "telemetry.sampler" in sys.modules:
            del sys.modules["telemetry.sampler"]


def test_sample_baseline_drop_caches_permission_error(mock_pynvml, mock_meminfo):
    """sample_baseline() still returns valid baseline when drop_caches raises PermissionError."""
    sampler, _ = _make_sampler_with_mock_meminfo(mock_pynvml, mock_meminfo)
    try:
        from telemetry.uma_model import UMAMemModel
        import telemetry.uma_model as uma_module

        model = UMAMemModel(sampler)

        # Patch the module-level _DROP_CACHES_PATH with a mock Path
        mock_path = MagicMock(spec=Path)
        mock_path.write_text.side_effect = PermissionError("no root")
        with patch.object(uma_module, "_DROP_CACHES_PATH", mock_path):
            baseline = model.sample_baseline()

        # Should succeed despite PermissionError
        assert "mem_available_gb" in baseline
        assert "timestamp" in baseline
    finally:
        if "telemetry.sampler" in sys.modules:
            del sys.modules["telemetry.sampler"]


def test_sample_baseline_drop_caches_logs_warning(mock_pynvml, mock_meminfo, caplog):
    """sample_baseline() logs a warning indicating dirty baseline when drop_caches fails."""
    sampler, _ = _make_sampler_with_mock_meminfo(mock_pynvml, mock_meminfo)
    try:
        from telemetry.uma_model import UMAMemModel
        import telemetry.uma_model as uma_module

        model = UMAMemModel(sampler)

        mock_path = MagicMock(spec=Path)
        mock_path.write_text.side_effect = PermissionError("no root")

        with caplog.at_level(logging.WARNING, logger="telemetry.uma_model"):
            with patch.object(uma_module, "_DROP_CACHES_PATH", mock_path):
                model.sample_baseline()

        # A warning about dirty baseline must be logged
        warning_text = " ".join(caplog.messages)
        assert "dirty baseline" in warning_text.lower(), (
            f"Expected 'dirty baseline' warning, got: {warning_text!r}"
        )
    finally:
        if "telemetry.sampler" in sys.modules:
            del sys.modules["telemetry.sampler"]


def test_calculate_headroom_default_jitter():
    """calculate_headroom uses 5 GB jitter margin and returns correct values."""
    from telemetry.uma_model import UMAMemModel

    baseline = {"mem_available_gb": 80.0}
    current = {"mem_available_gb": 60.0}
    result = UMAMemModel.calculate_headroom(
        baseline=baseline,
        current=current,
        tier_headroom_pct=20,
        jitter_margin_gb=5.0,
    )

    # safe_threshold = 80.0 * 0.20 + 5.0 = 21.0
    assert abs(result["safe_threshold"] - 21.0) < 0.01, (
        f"Expected safe_threshold=21.0, got {result['safe_threshold']}"
    )
    # headroom_gb = 60.0 - 21.0 = 39.0
    assert abs(result["headroom_gb"] - 39.0) < 0.01, (
        f"Expected headroom_gb=39.0, got {result['headroom_gb']}"
    )
    # headroom_pct = 39.0 / 60.0 * 100 = 65.0
    assert abs(result["headroom_pct"] - 65.0) < 0.01, (
        f"Expected headroom_pct=65.0, got {result['headroom_pct']}"
    )


def test_calculate_headroom_pin_memory_false():
    """calculate_headroom always returns pin_memory=False (UMA constraint)."""
    from telemetry.uma_model import UMAMemModel

    result = UMAMemModel.calculate_headroom(
        baseline={"mem_available_gb": 80.0},
        current={"mem_available_gb": 60.0},
        tier_headroom_pct=20,
    )
    assert result["pin_memory"] is False


def test_calculate_headroom_prefetch_capped():
    """calculate_headroom returns prefetch_factor <= 4."""
    from telemetry.uma_model import UMAMemModel

    result = UMAMemModel.calculate_headroom(
        baseline={"mem_available_gb": 80.0},
        current={"mem_available_gb": 60.0},
        tier_headroom_pct=20,
    )
    assert result["prefetch_factor"] <= 4, (
        f"prefetch_factor must be <= 4 (UMA), got {result['prefetch_factor']}"
    )
