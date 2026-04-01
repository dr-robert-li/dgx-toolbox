"""Shared pytest fixtures for telemetry package tests."""

import pytest
from unittest.mock import MagicMock, patch
import sys


@pytest.fixture()
def mock_pynvml():
    """Patch pynvml so GPUSampler enters mock mode in CI."""
    mock_mod = MagicMock()
    mock_mod.NVMLError = type("NVMLError", (Exception,), {})
    mock_mod.nvmlInit.side_effect = mock_mod.NVMLError("No GPU in CI")
    mock_mod.NVML_TEMPERATURE_GPU = 0
    with patch.dict(sys.modules, {"pynvml": mock_mod}):
        yield mock_mod


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
