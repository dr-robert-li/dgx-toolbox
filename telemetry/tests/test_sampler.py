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


def _make_live_pynvml(mock_meminfo, power_side_effect=None, temp_side_effect=None, util_side_effect=None):
    """Helper: create a mock pynvml module for live-mode tests with optional per-metric failures."""
    mock_mod = MagicMock()
    mock_mod.NVMLError = type("NVMLError", (Exception,), {})
    mock_mod.NVML_TEMPERATURE_GPU = 0
    mock_mod.nvmlInit.return_value = None
    mock_handle = MagicMock()
    mock_mod.nvmlDeviceGetHandleByIndex.return_value = mock_handle
    if power_side_effect:
        mock_mod.nvmlDeviceGetPowerUsage.side_effect = power_side_effect
    else:
        mock_mod.nvmlDeviceGetPowerUsage.return_value = 65000
    if temp_side_effect:
        mock_mod.nvmlDeviceGetTemperature.side_effect = temp_side_effect
    else:
        mock_mod.nvmlDeviceGetTemperature.return_value = 55
    if util_side_effect:
        mock_mod.nvmlDeviceGetUtilizationRates.side_effect = util_side_effect
    else:
        util_mock = MagicMock()
        util_mock.gpu = 42
        mock_mod.nvmlDeviceGetUtilizationRates.return_value = util_mock
    return mock_mod


class _patch_live_pynvml:
    """Context manager that patches pynvml AND clears stale telemetry.sampler cache.

    Order matters: first patch sys.modules["pynvml"], THEN clear telemetry.sampler
    so the reimport inside the test picks up the mock module.
    """

    def __init__(self, mock_mod):
        self._mock_mod = mock_mod
        self._ctx = patch.dict(sys.modules, {"pynvml": mock_mod})
        self._saved = {}

    def __enter__(self):
        import telemetry as _pkg
        # Step 1: patch pynvml in sys.modules
        self._ctx.__enter__()
        # Step 2: clear telemetry modules AND package attrs so reimport sees mock pynvml
        for k in ("telemetry.sampler", "telemetry.uma_model"):
            if k in sys.modules:
                self._saved[k] = sys.modules.pop(k)
            attr = k.split(".")[-1]
            if hasattr(_pkg, attr):
                self._saved[f"_attr_{attr}"] = getattr(_pkg, attr)
                delattr(_pkg, attr)
        return self._mock_mod

    def __exit__(self, *a):
        import telemetry as _pkg
        # Clean up any test-loaded modules
        for k in ("telemetry.sampler", "telemetry.uma_model"):
            sys.modules.pop(k, None)
            attr = k.split(".")[-1]
            if hasattr(_pkg, attr):
                delattr(_pkg, attr)
        # Unpatch pynvml
        self._ctx.__exit__(*a)
        # Restore originals
        for k, v in self._saved.items():
            if k.startswith("_attr_"):
                setattr(_pkg, k[6:], v)
            else:
                sys.modules[k] = v


def test_partial_nvml_power_failure(mock_meminfo):
    """If nvmlDeviceGetPowerUsage raises NVMLError, watts is None but other fields are present."""
    mock_mod = _make_live_pynvml(mock_meminfo)
    mock_mod.nvmlDeviceGetPowerUsage.side_effect = mock_mod.NVMLError("not supported")
    with _patch_live_pynvml(mock_mod):
        from telemetry import sampler as sampler_module
        sampler_module._MEMINFO_PATH = mock_meminfo
        result = sampler_module.GPUSampler().sample()
        assert result["watts"] is None
        assert result["temperature_c"] == 55
        assert result["gpu_util_pct"] == 42


def test_partial_nvml_temp_failure(mock_meminfo):
    """If nvmlDeviceGetTemperature raises NVMLError, temperature_c is None."""
    mock_mod = _make_live_pynvml(mock_meminfo)
    mock_mod.nvmlDeviceGetTemperature.side_effect = mock_mod.NVMLError("not supported")
    with _patch_live_pynvml(mock_mod):
        from telemetry import sampler as sampler_module
        sampler_module._MEMINFO_PATH = mock_meminfo
        result = sampler_module.GPUSampler().sample()
        assert result["temperature_c"] is None
        assert result["watts"] == 65.0


def test_partial_nvml_util_failure(mock_meminfo):
    """If nvmlDeviceGetUtilizationRates raises NVMLError, gpu_util_pct is None."""
    mock_mod = _make_live_pynvml(mock_meminfo)
    mock_mod.nvmlDeviceGetUtilizationRates.side_effect = mock_mod.NVMLError("not supported")
    with _patch_live_pynvml(mock_mod):
        from telemetry import sampler as sampler_module
        sampler_module._MEMINFO_PATH = mock_meminfo
        result = sampler_module.GPUSampler().sample()
        assert result["gpu_util_pct"] is None
        assert result["watts"] == 65.0
        assert result["temperature_c"] == 55


def test_meminfo_missing_key(tmp_path):
    """_read_meminfo returns 0.0 for a key that doesn't exist in the file."""
    meminfo = tmp_path / "meminfo"
    meminfo.write_text("MemTotal:  131072000 kB\n")
    mock_mod = MagicMock()
    mock_mod.NVMLError = type("NVMLError", (Exception,), {})
    mock_mod.nvmlInit.side_effect = mock_mod.NVMLError("no gpu")
    with patch.dict(sys.modules, {"pynvml": mock_mod}):
        if "telemetry.sampler" in sys.modules:
            del sys.modules["telemetry.sampler"]
        from telemetry import sampler as sampler_module
        sampler_module._MEMINFO_PATH = meminfo
        result = sampler_module.GPUSampler()._read_meminfo("MemAvailable")
        assert result == 0.0
    if "telemetry.sampler" in sys.modules:
        del sys.modules["telemetry.sampler"]


def test_meminfo_permission_denied(tmp_path):
    """_read_meminfo returns 0.0 when /proc/meminfo is not readable."""
    mock_mod = MagicMock()
    mock_mod.NVMLError = type("NVMLError", (Exception,), {})
    mock_mod.nvmlInit.side_effect = mock_mod.NVMLError("no gpu")
    with patch.dict(sys.modules, {"pynvml": mock_mod}):
        if "telemetry.sampler" in sys.modules:
            del sys.modules["telemetry.sampler"]
        from telemetry import sampler as sampler_module
        sampler_module._MEMINFO_PATH = tmp_path / "nonexistent"
        result = sampler_module.GPUSampler()._read_meminfo("MemAvailable")
        assert result == 0.0
    if "telemetry.sampler" in sys.modules:
        del sys.modules["telemetry.sampler"]


def test_sample_always_returns_all_keys(mock_meminfo):
    """sample() always returns all 6 keys even when some NVML calls fail."""
    mock_mod = _make_live_pynvml(mock_meminfo)
    mock_mod.nvmlDeviceGetPowerUsage.side_effect = mock_mod.NVMLError("fail")
    mock_mod.nvmlDeviceGetTemperature.side_effect = mock_mod.NVMLError("fail")
    mock_mod.nvmlDeviceGetUtilizationRates.side_effect = mock_mod.NVMLError("fail")
    with _patch_live_pynvml(mock_mod):
        from telemetry import sampler as sampler_module
        sampler_module._MEMINFO_PATH = mock_meminfo
        result = sampler_module.GPUSampler().sample()
        expected_keys = {"watts", "temperature_c", "gpu_util_pct", "mem_available_gb", "page_cache_gb", "mock"}
        assert set(result.keys()) == expected_keys
        assert result["watts"] is None
        assert result["temperature_c"] is None
        assert result["gpu_util_pct"] is None
        assert result["mem_available_gb"] > 0  # /proc/meminfo still works


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
