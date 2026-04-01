# Stack Research

**Domain:** GPU Telemetry Primitives — DGX Spark (aarch64, GB10 UMA) monitoring library
**Researched:** 2026-04-01
**Confidence:** HIGH for the hardware constraints and fallback strategy; MEDIUM for which NVML calls succeed vs fail on GB10 (community-sourced, no official NVIDIA documentation)

---

## Context: What Already Exists (Do Not Re-Research)

This document covers ONLY the new additions for v1.3. The previous stack (v1.1 Safety Harness) is documented in the prior version of this file and remains unchanged.

| Existing Component | Role | Interface Point |
|---|---|---|
| Python 3.12 + FastAPI + uvicorn | Safety harness gateway | v1.3 telemetry module is pure Python — no new frameworks needed |
| `harness/pyproject.toml` | Python package definition | GPU telemetry goes in `dgx_toolbox/telemetry/` — same package, new submodule |
| NGC base image `nvcr.io/nvidia/pytorch:26.02-py3` | Docker runtime | Already includes `libnvidia-ml.so` — no driver installation needed in containers |
| MLflow | Experiment tracking | May optionally receive telemetry events — already a project dependency |

The v1.3 telemetry module is a **pure-Python library** with no new framework dependencies. Stack additions are limited to monitoring primitives.

---

## Critical Hardware Constraint: GB10 UMA Architecture

This section must be understood before any implementation decision.

The DGX Spark GB10 uses **Unified Memory Architecture (UMA)**: 128 GB LPDDR5X is a single physical pool shared between CPU and GPU. There is no discrete framebuffer. This breaks the standard NVML memory reporting path.

**What NVML returns on GB10:**

| NVML call | GB10 result | Notes |
|---|---|---|
| `nvmlDeviceGetMemoryInfo()` | `NVML_ERROR_NOT_SUPPORTED` | No discrete framebuffer to query |
| `nvmlDeviceGetUtilizationRates()` | Returns values (works) | GPU compute utilization reporting functions |
| `nvmlDeviceGetTemperature()` | Returns values (works) | SoC thermal sensor exposed |
| `nvmlDeviceGetPowerUsage()` | Returns values (works, sometimes 0W) | Whole-SoC power — not GPU-only |
| `nvmlDeviceGetCount()` | Returns 1 | One logical device |

**Consequence for design:** The `GPUSampler` component must treat `nvmlDeviceGetMemoryInfo` as an expected failure and fall back to `/proc/meminfo` parsing for UMA memory state. This is not a bug to fix — it is the correct behavior on this hardware.

**Sources:**
- [NVML Support for DGX Spark — Community Solution](https://forums.developer.nvidia.com/t/nvml-support-for-dgx-spark-grace-blackwell-unified-memory-community-solution/358869) — MEDIUM confidence (community, no official NVML docs confirm)
- [nvtop GB10 issue #426](https://github.com/Syllo/nvtop/issues/426) — corroborating community evidence
- [MPS and Telemetry on GB10](https://forums.developer.nvidia.com/t/mps-support-and-telemetry-on-grace-blackwell-gb10-with-unified-memory/363137) — MEDIUM confidence

---

## Recommended Stack (New Additions Only)

### Core Telemetry Libraries

| Technology | Version | Purpose | Why Recommended |
|---|---|---|---|
| nvidia-ml-py | 13.595.45 | NVML Python bindings — GPU utilization, temperature, power | Canonical replacement for deprecated `pynvml`. Pure Python (`py3-none-any` wheel), loads `libnvidia-ml.so` via ctypes at runtime. Already present in NGC PyTorch containers (`nvcr.io/nvidia/pytorch:26.02-py3`). Import path unchanged: `from pynvml import nvmlInit, nvmlDeviceGetHandleByIndex, ...`. Version 13.595 corresponds to driver 595, the current DGX Spark release. |
| psutil | 7.2.0 | UMA memory fallback — reads `/proc/meminfo` fields: `MemTotal`, `MemAvailable`, `MemFree`, `Cached`, `SwapFree` | The only correct way to measure memory state on GB10 UMA when NVML memory reporting fails. psutil's `virtual_memory()` wraps `/proc/meminfo` with a stable API and manylinux aarch64 wheels available. Use `MemAvailable` (not `MemFree`) — `MemAvailable` accounts for reclaimable page cache, which is critical on UMA where the CUDA allocator and page cache share the same physical pool. |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---|---|---|---|
| dataclasses (stdlib) | Python 3.12 stdlib | AnchorStore record types, GPUSample named tuples | Use `@dataclass(frozen=True)` for immutable sample records; mutable `@dataclass` for anchor entries. No new dependency — stdlib only. |
| json (stdlib) | Python 3.12 stdlib | AnchorStore persistence (read/write JSON files to disk) | Use for anchor file serialization. No new dependency — stdlib only. |
| threading (stdlib) | Python 3.12 stdlib | GPUSampler background polling thread | Use `threading.Thread(daemon=True)` for the sampling loop. Daemon threads exit cleanly when the main process exits — no explicit lifecycle management needed. Use `threading.Event` as a stop signal. |
| pathlib (stdlib) | Python 3.12 stdlib | Anchor file path resolution, `/proc/meminfo` path construction | Standard. No new dependency. |

### Optional: System-Level OOM Protection

These are **host-level system packages**, not pip dependencies. They are not part of the Python telemetry module — they operate as independent OS daemons. Include in setup documentation, not in `pyproject.toml`.

| Tool | Version | Purpose | When to Use |
|---|---|---|---|
| earlyoom | 1.8.2+ | System-level early OOM killer — terminates highest-oom_score process before the kernel enters uninterruptible sleep | Install on DGX Spark host (`sudo apt install earlyoom`) for any user running training workloads. The GB10 UMA hang-to-zombie failure mode (where the entire machine becomes unresponsive rather than the process crashing cleanly) is mitigated significantly by earlyoom. The telemetry module cannot prevent this at the Python level alone. |

---

## What NOT to Add

| Avoid | Why | Use Instead |
|---|---|---|
| `pynvml` (the package) | Deprecated since NGC container 25.09-py3. Identical API to `nvidia-ml-py` but emits `FutureWarning` on import. Already being removed from NGC containers. | `nvidia-ml-py` 13.595.45 — same import path, same API, no warning |
| DCGM (Data Center GPU Manager) | Explicitly not supported on DGX Spark GB10. NVIDIA confirmed "no plans to support DCGM on Spark" — it requires discrete-framebuffer GPU architecture. | `nvidia-ml-py` for what works + `/proc/meminfo` for UMA memory |
| nvidia-smi subprocess calls | Subprocess introduces 100–500ms latency per call and is fragile when called from inside training containers. The telemetry spec explicitly requires "no subprocess calls". Use the NVML Python bindings directly. | `nvidia-ml-py` Python API |
| `torch.cuda.memory_allocated()` / `torch.cuda.mem_get_info()` | On GB10 UMA, `cudaMemGetInfo` conflates "physically free" with "available to CUDA" — it does not represent true system memory availability. Additionally, PyTorch issue #174358 shows that on GB10, `cudaMemGetInfo` can trigger the same allocator instability that causes system hangs. Do not use for headroom calculation. | `/proc/meminfo` via psutil for physical UMA state; `nvidia-ml-py` for GPU compute utilization only |
| prometheus-client or OpenMetrics stack | Overkill for a single-node embedded telemetry module. The telemetry library exports a Python dataclass, not a metrics endpoint. The caller (training scripts) decides what to do with the sample. | Direct Python API — `sampler.sample()` returns a `GPUSample` dataclass |
| Grafana / Prometheus | No network monitoring infrastructure exists on DGX Spark. Single-node training tool. | MLflow for logging experiment-correlated telemetry snapshots (already in stack) |
| CUPTI (CUDA Profiling Tools Interface) | Correct tool for per-kernel GPU utilization on GB10, but requires CUDA toolkit headers, privileged access, and process injection. Complexity-to-value ratio is too high for this use case. | `nvmlDeviceGetUtilizationRates()` for coarse compute utilization |

---

## Integration Points

### Where the Module Lives

```
dgx_toolbox/
  telemetry/
    __init__.py          # Public API: GPUSampler, UMAModel, AnchorStore, ProbeProtocol, FailureClassifier
    sampler.py           # GPUSampler — polls NVML + /proc/meminfo
    uma_model.py         # UMAModel — headroom calculation, jitter margin
    scale.py             # EffectiveScale — multiplier tables, tier classification
    anchor.py            # AnchorStore — JSON persistence, override rules
    probe.py             # ProbeProtocol — prepare/evaluate cycle
    classifier.py        # FailureClassifier — clean/oom/hang/thermal/pressure
```

The `dgx_toolbox.py` bridge script in `examples/` imports from `dgx_toolbox.telemetry` and exposes a CLI entry point. The `status.sh` GPU telemetry block calls the bridge script via a one-shot `python -c "..."` invocation (acceptable in a status display context — not in training hot loops).

### Dependency Declaration (pyproject.toml additions)

```toml
[project]
dependencies = [
    # existing...
    "nvidia-ml-py>=13.595,<14",
    "psutil>=7.0,<8",
]

[project.optional-dependencies]
telemetry = [
    "nvidia-ml-py>=13.595,<14",
    "psutil>=7.0,<8",
]
```

Keep the telemetry extras separate so non-GPU deployments (CI runners, macOS dev machines without NVIDIA drivers) can install the package without pulling in NVML bindings. The `GPUSampler` must handle `ImportError` on `nvidia-ml-py` gracefully by degrading to `/proc/meminfo`-only mode.

### NVML Initialization Pattern

```python
# Correct initialization for GB10 — gracefully handles missing driver or UMA restrictions
try:
    from pynvml import (
        nvmlInit, nvmlShutdown,
        nvmlDeviceGetCount, nvmlDeviceGetHandleByIndex,
        nvmlDeviceGetMemoryInfo, nvmlDeviceGetUtilizationRates,
        nvmlDeviceGetTemperature, NVML_TEMPERATURE_GPU,
        NVMLError, NVMLError_NotSupported,
    )
    nvmlInit()
    _NVML_AVAILABLE = True
except Exception:
    _NVML_AVAILABLE = False
```

`nvmlDeviceGetMemoryInfo` must be called inside a `try/except NVMLError_NotSupported` block, not assumed to work. When it raises, fall back to psutil `/proc/meminfo` parsing.

### UMA Memory Reading Pattern

```python
import psutil

def _read_uma_state():
    vm = psutil.virtual_memory()
    return {
        "total_bytes": vm.total,
        "available_bytes": vm.available,   # MemAvailable — use this, not vm.free
        "used_bytes": vm.used,
        "percent_used": vm.percent,
    }
```

`vm.available` maps to Linux `MemAvailable` (kernel 3.14+), which accounts for page cache that the kernel can reclaim. On GB10 where the CUDA allocator competes with the page cache for the same LPDDR5X pool, `MemAvailable` is the correct signal for "how much can a training job actually use without triggering the zombie failure mode."

Also read `/proc/pressure/memory` (PSI — Pressure Stall Information) for the earliest warning of memory stall. Available on Ubuntu 22.04+ with `CONFIG_PSI=y` (default on DGX OS).

---

## Version Compatibility

| Package | Compatible With | Notes |
|---|---|---|
| nvidia-ml-py 13.595.45 | Python 3.6+, aarch64 via pure-Python ctypes | Requires `libnvidia-ml.so.1` on host — present in NGC containers and DGX OS. The `.45` in the version is the NVML API revision; `13` matches driver 595 generation. |
| psutil 7.2.0 | Python 3.6+, aarch64 manylinux wheel available | `manylinux_2_17_aarch64` wheel available on PyPI. No compilation needed on aarch64 if using the manylinux wheel. |
| Both | NGC PyTorch 26.02-py3 base | `nvidia-ml-py` is present in the NGC container as a PyTorch internal dependency. `psutil` is not always present — declare as explicit dependency. |

---

## Failure Mode Reference

This is directly relevant to the `FailureClassifier` implementation decisions.

| Failure Class | Observable Signal | Detection Approach |
|---|---|---|
| `CLEAN` | Process exits with `RuntimeError: CUDA out of memory` | Exit code non-zero, stderr contains "CUDA out of memory" |
| `OOM` (UMA zombie) | System becomes unresponsive; SSH hangs; no exit code | Heartbeat thread stops responding; PSI memory stall exceeds threshold; MemAvailable < 2% |
| `HANG` | Process alive, GPU utilization 0% for >N seconds | nvmlDeviceGetUtilizationRates returns 0 continuously with no training progress |
| `THERMAL` | GPU temperature exceeds threshold; training slows | nvmlDeviceGetTemperature > configurable threshold (suggest 85°C for GB10 SoC) |
| `PRESSURE` | MemAvailable dropping but not yet critical; PSI stall increasing | MemAvailable < configurable headroom threshold; `/proc/pressure/memory` stall time increasing |
| `WATCHDOG` | Override from anchor store (user manually flagged a run) | Anchor store entry with `reason=WATCHDOG` for this batch/config combination |

The most dangerous failure on GB10 is the OOM zombie: by the time the kernel OOM killer would trigger, the nvidia-modeset kernel thread may already be in uninterruptible D-state. The `FailureClassifier` must treat `PRESSURE` as an early warning and trigger a clean abort before reaching `OOM`.

---

## Sources

- [nvidia-ml-py on PyPI](https://pypi.org/project/nvidia-ml-py/) — version 13.595.45, March 19, 2026 (HIGH confidence, official registry)
- [psutil on PyPI](https://pypi.org/project/psutil/) — version 7.2.0, January 2026, aarch64 manylinux wheels available (HIGH confidence, official registry)
- [psutil documentation — virtual_memory()](https://psutil.readthedocs.io/) — MemAvailable mapping on Linux (HIGH confidence, official docs)
- [pynvml deprecation warning — NGC forum](https://forums.developer.nvidia.com/t/pynvml-package-is-deprecated-warning-in-nvcr-io-nvidia-pytorch-25-09-py3/348569) — deprecation confirmed in NGC 25.09+ containers (MEDIUM confidence, community)
- [NVML Support for DGX Spark — Community Solution](https://forums.developer.nvidia.com/t/nvml-support-for-dgx-spark-grace-blackwell-unified-memory-community-solution/358869) — nvmlDeviceGetMemoryInfo fails with NVML_ERROR_NOT_SUPPORTED on GB10 (MEDIUM confidence, community solution, no official NVML docs confirmation)
- [MPS and Telemetry on GB10 forum](https://forums.developer.nvidia.com/t/mps-support-and-telemetry-on-grace-blackwell-gb10-with-unified-memory/363137) — DCGM not supported; CUDA runtime + /proc/meminfo is the community workaround (MEDIUM confidence, community)
- [DGX Spark becomes zombie instead of OOM](https://forums.developer.nvidia.com/t/dgx-spark-becomes-unresponsive-zombie-instead-of-throwing-cuda-oom/353752) — UMA zombie failure mode mechanics (MEDIUM confidence, community reports)
- [Mitigating OOM freezes on UMA](https://forums.developer.nvidia.com/t/mitigating-oom-system-freezes-on-uma-based-single-board-computers/362769) — earlyoom recommendation; PSI /proc/pressure/memory signals (MEDIUM confidence, community)
- [PyTorch issue #174358](https://github.com/pytorch/pytorch/issues/174358) — cudaMemGetInfo causes allocator instability on GB10 (MEDIUM confidence, PyTorch issue tracker, Feb 2026)
- [nvtop GB10 issue #426](https://github.com/Syllo/nvtop/issues/426) — nvmlDeviceGetMemoryInfo N/A on GB10; per-process memory works (MEDIUM confidence, community)
- [nvidia-ml-py pure-Python mechanism](https://pypi.org/project/nvidia-ml-py/) — py3-none-any wheel uses ctypes to dlopen libnvidia-ml.so; works on any arch with the driver present (HIGH confidence, PyPI metadata)

---

*Stack research for: v1.3 GPU Telemetry Primitives — DGX Spark aarch64, GB10 UMA*
*Researched: 2026-04-01*
*Previous milestone stack (v1.1 Safety Harness) documented in git history — this file supersedes for the current milestone*
