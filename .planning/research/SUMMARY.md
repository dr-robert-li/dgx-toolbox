# Project Research Summary

**Project:** DGX Toolbox v1.3 — GPU Telemetry Primitives
**Domain:** GPU hardware sampling, UMA memory modeling, adaptive batch sizing for DGX Spark (Grace Blackwell GB10, aarch64, unified memory)
**Researched:** 2026-04-01
**Confidence:** MEDIUM-HIGH overall (stack HIGH for what works, MEDIUM for GB10-specific NVML limits; architecture HIGH; features HIGH for table stakes, MEDIUM for scale formula; pitfalls HIGH for UMA and pynvml, MEDIUM for classifier edge cases)

## Executive Summary

The v1.3 milestone adds a self-contained Python telemetry package (`dgx_toolbox.telemetry`) to the existing DGX Toolbox. The package provides six primitives — `GPUSampler`, `UMAMemModel`, `ScaleFormula`, `AnchorStore`, `ProbeProtocol`, and `FailureClassifier` — that give training scripts a hardware-aware foundation without requiring them to implement raw NVML or `/proc` calls themselves. The entire implementation uses only stdlib plus two new pip dependencies (`nvidia-ml-py>=13.595` and `psutil>=7.0`), and it integrates cleanly into the existing `DGXToolbox` validation engine and `status.sh` dashboard. No new frameworks are required.

The central constraint that shapes every design decision is the GB10 Unified Memory Architecture: the GPU shares a single 128 GB LPDDR5X pool with the CPU and has no dedicated framebuffer. This means `nvmlDeviceGetMemoryInfo` returns `NVML_ERROR_NOT_SUPPORTED`, `cudaMemGetInfo` underreports allocatable memory by excluding reclaimable page cache, and the correct authoritative source for memory state is `/proc/meminfo` `MemAvailable`. All other NVML calls (utilization, temperature, clocks, power) work normally. Any code that ignores this constraint will fail silently on this hardware while passing all CI tests on discrete-GPU machines.

The most dangerous failure mode on GB10 is the UMA zombie: when the system runs out of memory, the nvidia-modeset kernel thread can enter uninterruptible D-state, making the entire machine unresponsive rather than killing just the training process. The `FailureClassifier` and `UMAMemModel` exist to detect `PRESSURE` conditions early — before the OS OOM killer activates — and abort cleanly. Host-level installation of `earlyoom` is the safety net for cases where the library cannot intervene in time. This architecture is deliberately conservative: probe before committing to a batch size, hold that size constant during training, and never attempt mid-training batch size changes.

## Key Findings

### Recommended Stack

The telemetry module is pure Python with no new framework dependencies. Two libraries are added to `pyproject.toml`: `nvidia-ml-py 13.595.45` (the official NVIDIA NVML binding, import name `pynvml`, replaces the deprecated `pynvml` PyPI package) and `psutil 7.2.0` (wraps `/proc/meminfo` with a stable API, aarch64 manylinux wheels available). All other dependencies — `dataclasses`, `json`, `threading`, `pathlib` — are Python 3.12 stdlib. The NGC `nvcr.io/nvidia/pytorch:26.02-py3` base image already includes `libnvidia-ml.so`, so no driver installation is needed in containers.

**Core technologies:**
- `nvidia-ml-py 13.595.45`: NVML Python bindings (GPU utilization, temperature, clocks, power) — canonical NVIDIA-maintained package; pure Python ctypes wheel works on aarch64 without compilation
- `psutil 7.2.0`: UMA memory fallback via `/proc/meminfo` `MemAvailable` — the only correct way to measure memory headroom on GB10 where NVML memory APIs are unsupported
- `earlyoom 1.8.2+` (host OS package, not pip): system-level OOM killer daemon to prevent zombie hangs — install on DGX Spark host, not in containers

**Critical version requirements:**
- `nvidia-ml-py` must be `>=13.595,<14` to match the DGX Spark driver 595 generation
- The deprecated `pynvml` package must NOT be installed alongside `nvidia-ml-py` — both expose `import pynvml` and shadow each other unpredictably

### Expected Features

All six v1.3 primitives are must-haves; there are no features to defer within the core milestone. The dependency chain is strict: `GPUSampler` and `UMAMemModel` are foundations; everything else builds on them.

**Must have (table stakes — v1.3):**
- `GPUSampler` — pynvml init guard, `sample_once()`, context manager, `/proc/meminfo` fallback for UMA memory; foundation for all other components
- `UMAMemModel` — rolling baseline, headroom = `MemAvailable` minus 12% jitter margin; without this, batch size decisions on GB10 will be wrong
- `AnchorStore` — JSON persistence keyed on `(model_id, dtype, seq_len, memory_tier)` with OOM/COMPLETED/HANG/WATCHDOG override rules and 30-day expiry; atomic write mandatory
- `ProbeProtocol` — prepare (forward-pass only, `no_grad`) + evaluate (N=5 steps) cycle; writes outcome to anchor store; must follow the out-of-except OOM recovery pattern
- `FailureClassifier` — multi-signal classification (exit code + dmesg OOM lines + wall time) to clean/oom/hang/thermal/pressure enum; exit code 137 alone is ambiguous
- `ScaleFormula` — effective scale = `gpu_util% * clock_ratio * thermal_factor` → FULL/THROTTLED/DEGRADED/CRITICAL tier; operates on physical micro-batch size, not effective batch size

**Should have (v1.3.x after validation):**
- Background sampler with ring buffer — for continuous logging during long training runs
- JSONL telemetry log — rotating file for post-run analysis
- Per-model baseline profiles — model-aware memory baselines in anchor store

**Defer (v2+):**
- OTEL/Prometheus export — add as optional extras when local observability infra exists
- Multi-GPU aggregation — API is device-index-aware by design; implement when hardware warrants
- Predictive failure modeling — requires 6+ months of anchor store failure logs to train

**Anti-features (do not build):**
- Auto-adjusting batch size during training — breaks gradient accumulation math and optimizer state consistency
- Background sampler always on — adds NVML overhead during training; opt-in only
- `nvidia-smi` subprocess calls — 50-200ms latency per call, not usable in sampling loops

### Architecture Approach

The `telemetry/` package lives at the repository root (not inside `harness/`) so it can be imported independently by `examples/dgx_toolbox.py`, `status.sh`, and training containers without requiring the safety harness to be running. Components communicate only via direct Python imports; there is no HTTP or subprocess coupling within the telemetry layer. The anchor store writes host-local JSON (`telemetry/data/anchors.json`) mounted as a volume so state persists across container restarts — a pattern already established by the existing training containers.

**Major components:**
1. `GPUSampler` (`sampler.py`) — NVML compute metrics only; explicitly excludes memory queries; graceful fallback on `NVMLError`
2. `UMAMemModel` (`uma.py`) — reads `MemAvailable` from `/proc/meminfo`; applies 12% jitter margin; exposes `headroom_bytes` as the single authoritative signal for batch size decisions
3. `ScaleFormula` (`scale.py`) — translates headroom to tier enum; inputs are physical micro-batch size, not effective batch size
4. `AnchorStore` (`anchors.py`) — composite key schema with memory tier bucket; atomic rename writes; `.bak` fallback on `JSONDecodeError`; 30-day expiry
5. `ProbeProtocol` (`probe.py`) — stateful prepare/evaluate orchestration; forward-pass only during evaluate; wires all other primitives
6. `FailureClassifier` (`classifier.py`) — multi-signal rules: exit code + dmesg OOM lines + temperature + wall time; defined first, used by everything downstream

**Recommended build order:** classifier → sampler → UMAMemModel → scale → anchors → probe → status.sh GPU block → dgx_toolbox.py bridge

### Critical Pitfalls

1. **`nvmlDeviceGetMemoryInfo` raises `NVMLError_NotSupported` on GB10** — catch with `except pynvml.NVMLError` (not `RuntimeError`), fall back to `/proc/meminfo`; this is the primary code path, not an edge case; must be built from day one in Phase 1

2. **`MemFree` vs `MemAvailable`** — always parse `MemAvailable`; `MemFree` can be 1-2 GB while `MemAvailable` shows 40 GB under normal load; using `MemFree` produces chronic false OOM pressure alarms; add a unit test asserting they can differ by >10x

3. **PyTorch OOM reference leak in except blocks** — recovery code inside the `except OOM` block cannot free CUDA memory because the exception object holds stack frame references; move all retry logic outside the `except` block using a flag; this is the structural foundation of the probe cycle

4. **Exit code 137 is ambiguous (OOM vs HANG vs external kill)** — check `dmesg` for kernel OOM lines keyed on the process PID; absent OOM lines with exit 137 = HANG/WATCHDOG, not OOM; misclassification causes unnecessary batch size reductions

5. **Anchor store key schema must be fixed before first write** — key on `(model_id, dtype, seq_len, memory_tier)` with timestamp and expiry from the start; changing the key schema after entries exist requires migration; stale anchors from a different memory environment cause immediate OOM on first step

6. **`pynvml` package vs `nvidia-ml-py` package confusion** — `pip install pynvml` installs the deprecated fork; `pip install nvidia-ml-py` installs the official NVIDIA package; both expose `import pynvml`; pin `nvidia-ml-py` in `pyproject.toml` and verify in CI that `pynvml` is not separately installed

## Implications for Roadmap

Research reveals a strict dependency ordering. The build order is dictated by two constraints: (1) hardware primitives must exist before higher-level abstractions, and (2) the anchor store schema and failure classification enum must be frozen before any component writes to them. Four phases cover the v1.3 scope cleanly.

### Phase 1: Hardware Sampling Foundation
**Rationale:** `GPUSampler` and `UMAMemModel` are the data sources for every other component. The GB10-specific UMA fallback path is the primary path, not an edge case — it must be correct before any higher-level logic is written on top of it. Getting `MemAvailable` vs `MemFree` wrong here invalidates every downstream calculation. `FailureClassifier` goes here too because it is pure Python with no hardware calls and defines the outcome enum everything else references.
**Delivers:** `FailureClassifier` (outcome enum), `GPUSampler` (NVML + `/proc/meminfo` fallback), `UMAMemModel` (headroom with jitter margin)
**Addresses:** Table stakes GPU sampling; UMA memory model; no-subprocess constraint
**Avoids:** Pitfalls 1 (NVMLError fallback), 2 (cudaMemGetInfo underreport), 3 (MemFree vs MemAvailable), 5 (pynvml package confusion), 12 (subprocess calls)
**Research flag:** Standard patterns — well-documented NVML init guard and `/proc/meminfo` parsing; no phase research needed

### Phase 2: Persistence and Scale Classification
**Rationale:** The anchor store schema must be frozen before the probe protocol writes to it. The scale formula must be defined with clear micro-batch vs effective-batch semantics before it is consumed by probe logic. Both components are relatively low-complexity but carry design decisions that are expensive to change later.
**Delivers:** `AnchorStore` (composite key schema, atomic writes, `.bak` fallback, 30-day expiry), `ScaleFormula` (tier table, explicit micro-batch input type)
**Addresses:** Anchor persistence; OOM/COMPLETED/HANG/WATCHDOG override rules; effective scale tier classification
**Avoids:** Pitfalls 7 (concurrent JSON corruption), 8 (stale anchor key schema), 9 (micro-batch vs effective-batch confusion)
**Research flag:** Standard patterns for atomic file writes; anchor key design is a local decision — no phase research needed

### Phase 3: Probe Protocol
**Rationale:** Probe is the highest-complexity component and the primary value delivery of v1.3. It requires all prior components (classifier, sampler, UMA model, scale formula, anchor store) to be complete. The OOM reference leak pattern (out-of-except retry) is the structural constraint that must be established before any probe code is written.
**Delivers:** `ProbeProtocol` (prepare/evaluate cycle, N=5 steps, forward-pass only, writes outcome to anchor store)
**Addresses:** Batch size probing before training; safe prepare/evaluate cycle; probe does not execute optimizer.step()
**Avoids:** Pitfalls 6 (PyTorch OOM reference leak), 10 (exit code 137 ambiguity via FailureClassifier), 11 (optimizer state corruption in probe)
**Research flag:** May benefit from a targeted research pass to confirm the exact `dmesg` OOM line format on DGX OS (Ubuntu 22.04 + GB10) before implementing the FailureClassifier dmesg parser — this format was not confirmed in the current research pass

### Phase 4: Integration and CLI Surface
**Rationale:** The `dgx_toolbox.py` bridge and `status.sh` GPU block are thin integration layers that validate the complete API surface end-to-end. Building them last ensures the public API is driven by real caller needs. The `status.sh` block can be unblocked as soon as Phase 1 completes (needs only sampler + UMA model); the full dgx_toolbox.py bridge waits for Phase 3.
**Delivers:** `status.sh` GPU telemetry block, `dgx_toolbox.py` bridge (`telemetry sample`, `telemetry probe`, `telemetry anchor` subcommands), full pytest suite mirroring `harness/tests/` structure
**Addresses:** CLI integration; status dashboard; end-to-end validation
**Avoids:** Anti-pattern of coupling telemetry to the safety harness — intentionally decoupled by placing `telemetry/` at repo root
**Research flag:** Standard patterns — existing `DGXToolbox` validation engine pattern is known from codebase; no research needed

### Phase Ordering Rationale

- `FailureClassifier` before `GPUSampler`: Defines the outcome enum that `AnchorStore` and `ProbeProtocol` reference; pure Python, no hardware dependency; eliminates circular type references downstream
- UMA hardware layer before persistence: The anchor store's composite key includes a `memory_tier` bucket derived from `UMAMemModel` total memory — the model must exist before the key schema can be finalized
- Persistence before probe: The probe writes to the anchor store on every evaluate cycle; write path, key schema, and override rules must be stable before probe logic is layered on top
- Integration last: Thin CLI/bash integration layers are fastest to build and easiest to revise once the API they wrap is stable and tested

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 3 (Probe Protocol / FailureClassifier dmesg parser):** The multi-signal failure classification uses `dmesg` OOM lines keyed on process PID. The exact kernel log message format for GB10 UMA OOM events on DGX OS was not confirmed in this research pass. Run a targeted research query on Ubuntu 22.04 OOM killer log format before implementing the parser.

Phases with standard patterns (skip research-phase):
- **Phase 1:** NVML init guard and `/proc/meminfo` parsing are well-documented; pynvml API is stable
- **Phase 2:** Atomic file writes via `os.replace` are POSIX-standard; anchor JSON schema is a local design decision
- **Phase 4:** Integration against existing known codebase patterns only

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | `nvidia-ml-py` and `psutil` confirmed on PyPI with aarch64 wheels; GB10 NVML behavior confirmed by official NVIDIA support doc plus multiple community corroborations |
| Features | HIGH (table stakes) / MEDIUM (scale formula) | GPU sampling and UMA fallback confirmed by official sources; effective scale formula tiers are community-derived with no single canonical reference |
| Architecture | HIGH | Consistent across official NVIDIA UMA docs, existing codebase analysis, and community NVML shim solutions; component boundaries are unambiguous |
| Pitfalls | HIGH (UMA/pynvml) / MEDIUM (classifier edge cases) / LOW (GB10 thermal specifics) | OOM zombie and MemAvailable findings backed by official sources; exit code 137 disambiguation is general Linux knowledge; GB10-specific thermal throttle API docs not found |

**Overall confidence:** MEDIUM-HIGH

### Gaps to Address

- **GB10 dmesg OOM line format:** No official documentation confirms the exact kernel log message format for UMA OOM events on GB10. The `FailureClassifier` dmesg parser must be validated against a real OOM event. Mitigation: implement with a configurable OOM message pattern and validate empirically in Phase 3 testing.
- **NVML throttle reason bitmask on GB10:** `nvmlDeviceGetCurrentClocksThrottleReasons` is documented for discrete GPUs; community sources confirm temperature/power readings work on GB10 but throttle reason flags have not been independently verified. Implement with graceful `NVMLError` fallback and validate during Phase 1.
- **Effective scale tier thresholds:** The FULL/THROTTLED/DEGRADED/CRITICAL boundaries are derived from community MFU benchmarks, not GB10-specific measurements. Design `ScaleFormula` with configurable tier boundaries and validate against actual DGX Spark training runs.
- **Probe N=5 steps default:** Cited as an "industry pattern" in FEATURES.md but no primary source was identified. Make configurable from day one.

## Sources

### Primary (HIGH confidence)
- [nvidia-ml-py on PyPI](https://pypi.org/project/nvidia-ml-py/) — version 13.595.45, aarch64 pure-Python wheel
- [psutil on PyPI](https://pypi.org/project/psutil/) — version 7.2.0, aarch64 manylinux wheel
- [Unexpected Available Memory Reporting on DGX Spark — NVIDIA Support](https://nvidia.custhelp.com/app/answers/detail/a_id/5728/~/unexpected-available-memory-reporting-on-dgx-spark) — cudaMemGetInfo underreports on UMA
- [DGX Spark User Guide — NVIDIA, Mar 2026](https://docs.nvidia.com/dgx/dgx-spark/dgx-spark.pdf) — official hardware and known issues
- [psutil documentation — virtual_memory()](https://psutil.readthedocs.io/) — MemAvailable mapping on Linux
- [NVML API Reference — nvmlDeviceGetCurrentClocksThrottleReasons](https://docs.nvidia.com/deploy/nvml-api/group__nvmlClocksThrottleReasons.html) — throttle bitmask semantics

### Secondary (MEDIUM confidence)
- [NVML Support for DGX Spark — Community Solution (NVIDIA Forums)](https://forums.developer.nvidia.com/t/nvml-support-for-dgx-spark-grace-blackwell-unified-memory-community-solution/358869) — nvmlDeviceGetMemoryInfo NOT_SUPPORTED on GB10
- [MPS and Telemetry on GB10 (NVIDIA Forums)](https://forums.developer.nvidia.com/t/mps-support-and-telemetry-on-grace-blackwell-gb10-with-unified-memory/363137) — DCGM not supported; /proc/meminfo workaround
- [DGX Spark becomes zombie instead of OOM (NVIDIA Forums)](https://forums.developer.nvidia.com/t/dgx-spark-becomes-unresponsive-zombie-instead-of-throwing-cuda-oom/353752) — UMA zombie failure mode
- [Mitigating OOM freezes on UMA (NVIDIA Forums)](https://forums.developer.nvidia.com/t/mitigating-oom-system-freezes-on-uma-based-single-board-computers/362769) — earlyoom; PSI /proc/pressure/memory
- [PyTorch issue #174358](https://github.com/pytorch/pytorch/issues/174358) — cudaMemGetInfo allocator instability on GB10
- [nvtop GB10 issue #426](https://github.com/Syllo/nvtop/issues/426) — nvmlDeviceGetMemoryInfo N/A on GB10
- [vLLM UMA memory bug — GitHub #35313](https://github.com/vllm-project/vllm/issues/35313) — nvmlDeviceGetMemoryInfo Not Supported in production
- [Farewell CUDA OOM — Databricks](https://www.databricks.com/blog/farewell-oom) — OOM reference leak in except blocks
- [Decoding GPU Efficiency — Clockwork.io](https://clockwork.io/blog/decoding-gpu-efficiency-part-1-the-flops-fallacy/) — MFU tier calibration
- [pynvml deprecation — NGC forum](https://forums.developer.nvidia.com/t/pynvml-package-is-deprecated-warning-in-nvcr-io-nvidia-pytorch-25-09-py3/348569) — deprecated in NGC 25.09+

---
*Research completed: 2026-04-01*
*Ready for roadmap: yes*
