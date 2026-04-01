"""GPU telemetry sampler for DGX Spark.

Wraps NVML (via nvidia-ml-py) for GPU metrics and reads /proc/meminfo for
memory metrics. Falls back to mock mode when libnvidia-ml.so.1 is absent
(CI environments, containers without GPU passthrough).

GB10 UMA architecture note (TELEM-02):
    nvmlDeviceGetMemoryInfo raises NVMLError_NotSupported on GB10/GB200.
    Memory is ALWAYS read from /proc/meminfo MemAvailable — this is the
    primary path, not a fallback. nvmlDeviceGetMemoryInfo is never called.
"""
from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Union

import pynvml

# Module-level constant so tests can patch it to a temp file.
_MEMINFO_PATH = Path("/proc/meminfo")


class GPUSampler:
    """Sample GPU and memory telemetry from a DGX Spark node.

    Attributes:
        _mock: True when NVML library is absent or unavailable.
        _handle: NVML device handle (None in mock mode).
    """

    def __init__(self) -> None:
        """Initialize the sampler.

        Tries to initialize NVML and get a device handle. Sets mock mode
        if any NVMLError is raised (covers libnvidia-ml.so.1 absent,
        no GPU present, and permission errors).
        """
        self._mock: bool = False
        self._handle = None
        try:
            pynvml.nvmlInit()
            self._handle = pynvml.nvmlDeviceGetHandleByIndex(0)
        except pynvml.NVMLError:
            self._mock = True

    @property
    def mock(self) -> bool:
        """Return True if running in mock mode (no GPU hardware available)."""
        return self._mock

    def sample(self) -> dict:
        """Sample current GPU and memory telemetry.

        Returns:
            Dict with keys:
                watts (float): GPU power draw in Watts.
                temperature_c (int): GPU temperature in Celsius.
                gpu_util_pct (int): GPU utilization percentage (0-100).
                mem_available_gb (float): Available memory from /proc/meminfo MemAvailable.
                page_cache_gb (float): Page cache size from /proc/meminfo Cached.
                mock (bool): True if no GPU hardware was available.

        Note:
            Memory is ALWAYS read from /proc/meminfo, never from
            nvmlDeviceGetMemoryInfo (GB10 UMA architecture — TELEM-02).
            No subprocess calls are made at any point.
        """
        if self._mock:
            # Memory is always read from /proc/meminfo (UMA architecture).
            # GPU NVML metrics (watts, temp, util) fall back to 0 when
            # libnvidia-ml.so.1 is absent, but /proc/meminfo is always available.
            return {
                "watts": 0.0,
                "temperature_c": 0,
                "gpu_util_pct": 0,
                "mem_available_gb": self._read_meminfo("MemAvailable"),
                "page_cache_gb": self._read_meminfo("Cached"),
                "mock": True,
            }

        watts = pynvml.nvmlDeviceGetPowerUsage(self._handle) / 1000.0
        temperature_c = pynvml.nvmlDeviceGetTemperature(
            self._handle, pynvml.NVML_TEMPERATURE_GPU
        )
        gpu_util_pct = pynvml.nvmlDeviceGetUtilizationRates(self._handle).gpu
        # Memory always from /proc/meminfo — GB10 UMA pattern (TELEM-02)
        mem_available_gb = self._read_meminfo("MemAvailable")
        page_cache_gb = self._read_meminfo("Cached")

        return {
            "watts": watts,
            "temperature_c": temperature_c,
            "gpu_util_pct": gpu_util_pct,
            "mem_available_gb": mem_available_gb,
            "page_cache_gb": page_cache_gb,
            "mock": False,
        }

    def _read_meminfo(self, key: str) -> float:
        """Read a value from /proc/meminfo and return it in gigabytes.

        Args:
            key: The meminfo field name without the colon (e.g., "MemAvailable").

        Returns:
            Value in GB (converted from kB). Returns 0.0 if key not found.
        """
        try:
            content = _MEMINFO_PATH.read_text()
        except OSError:
            return 0.0

        for line in content.splitlines():
            if line.startswith(f"{key}:"):
                # Format: "MemAvailable:   83886080 kB"
                parts = line.split()
                if len(parts) >= 2:
                    try:
                        kb = int(parts[1])
                        return kb / (1024 * 1024)
                    except ValueError:
                        return 0.0
        return 0.0

    def append_jsonl(self, path: Union[str, Path]) -> None:
        """Sample telemetry and append a JSON record to a NDJSON file.

        Args:
            path: Path to the NDJSON output file. Created if it does not exist.
                  Appended to if it already exists.
        """
        record = self.sample()
        record["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record) + "\n")
