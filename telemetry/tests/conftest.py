"""Shared pytest fixtures for telemetry package tests."""

import pytest
from unittest.mock import MagicMock, patch
import sys

# Telemetry modules that import pynvml (directly or transitively).
# These must be cleared from sys.modules when patching pynvml so the
# mock takes effect on fresh imports within the test. Without clearing,
# a previously cached telemetry.sampler module retains a reference to
# the real pynvml module even after sys.modules["pynvml"] is replaced.
_TELEMETRY_SAMPLER_MODULES = [
    "telemetry.sampler",
    "telemetry.uma_model",
]


@pytest.fixture()
def mock_pynvml():
    """Patch pynvml so GPUSampler enters mock mode in CI.

    Also clears and restores cached telemetry modules that depend on pynvml
    so that re-importing inside tests picks up the mock, regardless of
    whether previous tests loaded the real module.
    """
    mock_mod = MagicMock()
    mock_mod.NVMLError = type("NVMLError", (Exception,), {})
    mock_mod.nvmlInit.side_effect = mock_mod.NVMLError("No GPU in CI")
    mock_mod.NVML_TEMPERATURE_GPU = 0

    # Snapshot and clear cached modules before patching pynvml
    saved = {k: sys.modules.pop(k) for k in _TELEMETRY_SAMPLER_MODULES if k in sys.modules}
    try:
        with patch.dict(sys.modules, {"pynvml": mock_mod}):
            yield mock_mod
    finally:
        # Remove any re-cached modules loaded during the test
        for k in _TELEMETRY_SAMPLER_MODULES:
            sys.modules.pop(k, None)
        # Restore originals so tests that don't use mock_pynvml can import normally
        sys.modules.update(saved)


@pytest.fixture()
def mock_meminfo(tmp_path):
    """Provide a fake /proc/meminfo file for deterministic memory reads."""
    content = (
        "MemTotal:       131072000 kB\n"
        "MemFree:         6553600 kB\n"
        "MemAvailable:   83886080 kB\n"
        "Cached:         20971520 kB\n"
    )
    meminfo_file = tmp_path / "meminfo"
    meminfo_file.write_text(content)
    return meminfo_file
