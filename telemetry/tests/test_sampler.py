"""Tests for GPUSampler module (TELEM-01, TELEM-02, TELEM-03, TELEM-04)."""

import json
import pytest
from pathlib import Path
from unittest.mock import MagicMock, patch
import sys


def test_sample_returns_all_fields(mock_pynvml, tmp_path):
    """sample() returns dict with exactly the required keys in mock mode."""
    from telemetry.sampler import GPUSampler
    sampler = GPUSampler()
    result = sampler.sample()
    expected_keys = {"watts", "temperature_c", "gpu_util_pct", "mem_available_gb", "page_cache_gb", "mock"}
    assert set(result.keys()) == expected_keys
    assert result["mock"] is True


def test_mock_mode_no_gpu(mock_pynvml):
    """GPUSampler initializes without error in mock mode; sample() returns mock=True with zeroed numeric values."""
    from telemetry.sampler import GPUSampler
    sampler = GPUSampler()
    result = sampler.sample()
    assert result["mock"] is True
    assert result["watts"] == 0.0
    assert result["temperature_c"] == 0
    assert result["gpu_util_pct"] == 0


def test_live_sample_reads_meminfo(mock_meminfo):
    """In live mode, _read_meminfo('MemAvailable') reads from the patched meminfo file correctly."""
    # Simulate a "live" pynvml where nvmlInit does NOT raise
    mock_mod = MagicMock()
    mock_mod.NVMLError = type("NVMLError", (Exception,), {})
    mock_mod.NVML_TEMPERATURE_GPU = 0
    # nvmlInit succeeds (no exception)
    mock_mod.nvmlInit.return_value = None
    mock_handle = MagicMock()
    mock_mod.nvmlDeviceGetHandleByIndex.return_value = mock_handle
    mock_mod.nvmlDeviceGetPowerUsage.return_value = 65000  # 65W in milliwatts
    mock_mod.nvmlDeviceGetTemperature.return_value = 55
    util_mock = MagicMock()
    util_mock.gpu = 42
    mock_mod.nvmlDeviceGetUtilizationRates.return_value = util_mock

    with patch.dict(sys.modules, {"pynvml": mock_mod}):
        # Need to reimport to pick up the patched pynvml
        if "telemetry.sampler" in sys.modules:
            del sys.modules["telemetry.sampler"]
        from telemetry.sampler import GPUSampler
        sampler = GPUSampler()
        # Override the meminfo path to use the mock file
        import telemetry.sampler as sampler_module
        sampler_module._MEMINFO_PATH = mock_meminfo
        sampler2 = GPUSampler()
        # MemAvailable: 83886080 kB => 83886080 / (1024*1024) = 80.0 GB
        result = sampler2._read_meminfo("MemAvailable")
        assert abs(result - 80.0) < 0.01, f"Expected ~80.0, got {result}"

    # Clean up module cache so other tests start fresh
    if "telemetry.sampler" in sys.modules:
        del sys.modules["telemetry.sampler"]


def test_live_sample_reads_page_cache(mock_meminfo):
    """In live mode, _read_meminfo('Cached') returns ~20.0 GB."""
    mock_mod = MagicMock()
    mock_mod.NVMLError = type("NVMLError", (Exception,), {})
    mock_mod.NVML_TEMPERATURE_GPU = 0
    mock_mod.nvmlInit.return_value = None
    mock_handle = MagicMock()
    mock_mod.nvmlDeviceGetHandleByIndex.return_value = mock_handle

    with patch.dict(sys.modules, {"pynvml": mock_mod}):
        if "telemetry.sampler" in sys.modules:
            del sys.modules["telemetry.sampler"]
        from telemetry import sampler as sampler_module
        sampler_module._MEMINFO_PATH = mock_meminfo
        sampler = sampler_module.GPUSampler()
        # Cached: 20971520 kB => 20971520 / (1024*1024) = 20.0 GB
        result = sampler._read_meminfo("Cached")
        assert abs(result - 20.0) < 0.01, f"Expected ~20.0, got {result}"

    if "telemetry.sampler" in sys.modules:
        del sys.modules["telemetry.sampler"]


def test_append_jsonl(mock_pynvml, tmp_path):
    """append_jsonl creates file; each line is valid JSON with 'ts' key; 2 calls = 2 lines."""
    from telemetry.sampler import GPUSampler
    sampler = GPUSampler()
    out_file = tmp_path / "out.jsonl"

    sampler.append_jsonl(out_file)
    sampler.append_jsonl(out_file)

    lines = out_file.read_text().strip().splitlines()
    assert len(lines) == 2, f"Expected 2 lines, got {len(lines)}"
    for line in lines:
        record = json.loads(line)
        assert "ts" in record, f"Missing 'ts' key in record: {record}"


def test_sample_no_subprocess(mock_pynvml):
    """No subprocess.run or subprocess.Popen calls are made during sample()."""
    from telemetry.sampler import GPUSampler
    sampler = GPUSampler()
    with patch("subprocess.run") as mock_run, patch("subprocess.Popen") as mock_popen:
        sampler.sample()
        mock_run.assert_not_called()
        mock_popen.assert_not_called()


def test_uma_memory_fallback(mock_meminfo):
    """nvmlDeviceGetMemoryInfo is never called; memory comes from /proc/meminfo only."""
    mock_mod = MagicMock()
    mock_mod.NVMLError = type("NVMLError", (Exception,), {})
    mock_mod.NVML_TEMPERATURE_GPU = 0
    mock_mod.nvmlInit.return_value = None
    mock_handle = MagicMock()
    mock_mod.nvmlDeviceGetHandleByIndex.return_value = mock_handle
    mock_mod.nvmlDeviceGetPowerUsage.return_value = 65000
    mock_mod.nvmlDeviceGetTemperature.return_value = 55
    util_mock = MagicMock()
    util_mock.gpu = 42
    mock_mod.nvmlDeviceGetUtilizationRates.return_value = util_mock

    with patch.dict(sys.modules, {"pynvml": mock_mod}):
        if "telemetry.sampler" in sys.modules:
            del sys.modules["telemetry.sampler"]
        from telemetry import sampler as sampler_module
        sampler_module._MEMINFO_PATH = mock_meminfo
        sampler = sampler_module.GPUSampler()
        sampler.sample()
        # nvmlDeviceGetMemoryInfo must NEVER be called (UMA pattern: always use /proc/meminfo)
        mock_mod.nvmlDeviceGetMemoryInfo.assert_not_called()

    if "telemetry.sampler" in sys.modules:
        del sys.modules["telemetry.sampler"]
