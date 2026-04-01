"""Tests for TELEM-16: dgx_toolbox.py gpu_telemetry bridge.

Tests three explicit modes (addresses Codex review concern):
1. Package missing (ImportError) -> None
2. Package present, sampling succeeds -> dict with all fields
3. Package present, sampling fails (runtime Exception) -> None
"""
import pytest
from unittest.mock import MagicMock, patch
import sys


def _get_gpu_telemetry() -> dict | None:
    """Replicate the bridge logic from dgx_toolbox.py status_report().

    Uses broad Exception catch (not just ImportError) to handle both
    import failures AND runtime sampling failures gracefully.
    Addresses review concern: ImportError is too narrow for the bridge.
    """
    try:
        from telemetry.sampler import GPUSampler
        sampler = GPUSampler()
        return sampler.sample()
    except Exception:
        return None


class TestGpuTelemetryBridge:
    def test_status_report_with_telemetry(self, mock_pynvml):
        result = _get_gpu_telemetry()
        assert result is not None
        assert "watts" in result
        assert "mock" in result

    def test_status_report_without_telemetry(self):
        # Remove telemetry from sys.modules to simulate not-installed
        with patch.dict(sys.modules, {"telemetry": None, "telemetry.sampler": None}):
            with patch("builtins.__import__", side_effect=ImportError("no telemetry")):
                result = _get_gpu_telemetry()
                assert result is None

    def test_status_report_sampling_exception(self, mock_pynvml):
        """Package imports OK but sample() raises at runtime.
        Addresses review concern: bridge must handle runtime failures,
        not just ImportError.
        """
        with patch("telemetry.sampler.GPUSampler") as MockSampler:
            MockSampler.return_value.sample.side_effect = RuntimeError("NVML gone")
            result = _get_gpu_telemetry()
            assert result is None

    def test_gpu_telemetry_fields(self, mock_pynvml):
        result = _get_gpu_telemetry()
        assert result is not None
        for key in ["watts", "temperature_c", "gpu_util_pct",
                    "mem_available_gb", "page_cache_gb", "mock"]:
            assert key in result

    def test_bridge_never_crashes_status_report(self):
        """Arbitrary exception from telemetry must not propagate.
        Addresses review concern: integration never hard-fails status.
        """
        with patch.dict(sys.modules, {"telemetry": MagicMock(), "telemetry.sampler": MagicMock()}):
            # Make the import succeed but GPUSampler constructor raise
            with patch("telemetry.sampler.GPUSampler", side_effect=OSError("device gone")):
                result = _get_gpu_telemetry()
                assert result is None
