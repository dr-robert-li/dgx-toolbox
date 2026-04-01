---
phase: 13-gpu-telemetry-primitives
plan: 01
subsystem: telemetry
tags: [gpu-telemetry, pynvml, mock-mode, tdd, python-package]
dependency_graph:
  requires: []
  provides:
    - telemetry/pyproject.toml
    - telemetry/telemetry/__init__.py
    - telemetry/telemetry/failure_classifier.py
    - telemetry/telemetry/sampler.py
    - telemetry/tests/conftest.py
    - telemetry/tests/test_failure_classifier.py
    - telemetry/tests/test_sampler.py
    - telemetry/conftest.py
  affects: []
tech_stack:
  added:
    - nvidia-ml-py>=13.595,<14 (NVML Python bindings, pure Python wheel, aarch64 safe)
    - pytest>=8.0 (test framework, already installed as 9.0.2)
  patterns:
    - TDD with explicit RED/GREEN/REFACTOR phases per task
    - Mock mode via pynvml.NVMLError fallback (no GPU required in CI)
    - _MEMINFO_PATH module constant for test overriding
    - Root conftest.py path injection to fix namespace package collision
key_files:
  created:
    - telemetry/pyproject.toml
    - telemetry/telemetry/__init__.py
    - telemetry/telemetry/failure_classifier.py
    - telemetry/telemetry/sampler.py
    - telemetry/tests/__init__.py
    - telemetry/tests/conftest.py
    - telemetry/tests/test_failure_classifier.py
    - telemetry/tests/test_sampler.py
    - telemetry/conftest.py
  modified: []
decisions:
  - Root conftest.py path injection fixes namespace package collision between dgx-toolbox/telemetry/ directory and the installable telemetry package
  - HANG classification never contains batch_cap per TELEM-14; documented in both code comment and docstring
  - nvmlDeviceGetMemoryInfo never called anywhere; /proc/meminfo MemAvailable is the authoritative memory source (GB10 UMA)
metrics:
  duration_minutes: 5
  completed_date: "2026-04-01"
  tasks_completed: 2
  tasks_total: 2
  files_created: 9
  files_modified: 0
---

# Phase 13 Plan 01: GPU Telemetry Primitives — Package Scaffold, FailureClassifier, and GPUSampler Summary

**One-liner:** Installable `dgx-telemetry` Python package with NVML-backed GPUSampler (mock mode for CI) and training FailureClassifier (5 classifications, HANG never emits batch_cap).

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Package scaffold, conftest, and FailureClassifier (TDD) | 7db4adf | telemetry/pyproject.toml, telemetry/__init__.py, failure_classifier.py, conftest.py, tests/conftest.py, tests/test_failure_classifier.py |
| 2 | GPUSampler with mock mode and JSONL append (TDD) | 7ce9b66 | telemetry/sampler.py, tests/test_sampler.py |

## What Was Built

### Package Scaffold

`telemetry/pyproject.toml` defines the `dgx-telemetry` package with:
- `nvidia-ml-py>=13.595,<14` as the sole runtime dependency (pure Python wheel, aarch64 safe)
- `pynvml` intentionally absent — it's a dead fork that shadows the nvidia-ml-py namespace
- pytest>=8.0 as optional test dependency
- `[tool.setuptools.packages.find]` includes only `telemetry*`

### FailureClassifier (TELEM-13, TELEM-14)

`classify_failure(final_readings, exit_code, training_completed) -> dict` classifies training outcomes:

| Classification | Trigger Conditions |
|---------------|-------------------|
| `clean` | `training_completed=True` and `exit_code=0`; or no other pattern matched |
| `oom` | `gpu_util_pct < 10` and `mem_available_gb < 1.0` |
| `hang` | `gpu_util_pct < 10` and `cpu_pct > 90` and `duration_at_state_s >= 60` and `mem_available_gb > 10.0` |
| `thermal` | `temperature_c >= 85` |
| `pressure` | `mem_available_gb < 3.0` |

**TELEM-14 invariant:** HANG return dict never contains `batch_cap`. This prevents incorrect batch backoff on dataloader deadlocks where the issue is CPU-side (not memory-side).

### GPUSampler (TELEM-01, TELEM-02, TELEM-03, TELEM-04)

`GPUSampler` wraps NVML for GPU metrics and `/proc/meminfo` for memory:

- `sample() -> dict`: Returns `{watts, temperature_c, gpu_util_pct, mem_available_gb, page_cache_gb, mock}`
- `append_jsonl(path)`: Appends a JSON record with `ts` timestamp to a NDJSON file
- `_read_meminfo(key) -> float`: Reads kB value from `/proc/meminfo`, returns GB
- Mock mode: `nvmlInit()` raises `NVMLError` → `_mock=True`, all numerics zeroed

**TELEM-02 invariant:** `nvmlDeviceGetMemoryInfo` is never called. Memory always from `/proc/meminfo MemAvailable`. This is required by the GB10 UMA architecture where `nvmlDeviceGetMemoryInfo` raises `NVMLError_NotSupported`.

**No subprocess:** All reads use pure Python I/O (`pathlib.Path.read_text()`).

### Test Infrastructure

- `tests/conftest.py`: Shared `mock_pynvml` (patches pynvml NVMLError) and `mock_meminfo` (provides deterministic `/proc/meminfo` fixture) fixtures
- `conftest.py` (root): Inserts package source root into `sys.path` to prevent namespace package collision where `/home/robert_li/dgx-toolbox` on `sys.path` shadowed the editable install

## Test Results

```
14 passed in 0.03s
- test_failure_classifier.py: 7 tests (clean, oom, hang, thermal, pressure, hang_no_batch_cap, unknown_defaults_clean)
- test_sampler.py: 7 tests (returns_all_fields, mock_mode, live_meminfo_read, live_page_cache_read, append_jsonl, no_subprocess, uma_memory_fallback)
```

All tests pass without GPU hardware present.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Fixed namespace package collision with sys.path injection**
- **Found during:** Task 1 verification — pytest was importing the wrong `telemetry` namespace
- **Issue:** `/home/robert_li/dgx-toolbox` is on `sys.path` and Python resolved `dgx-toolbox/telemetry/` as a namespace package, shadowing the editable-installed `dgx-telemetry` package. The editable install finder is appended to `sys.meta_path` (last) so the built-in finder wins first.
- **Fix:** Added `telemetry/conftest.py` that inserts the package source root at `sys.path[0]` before any imports. This is consistent with the existing harness package pattern in this repo.
- **Files modified:** `telemetry/conftest.py` (created)
- **Commit:** 7db4adf

## Known Stubs

None — all implemented functionality is fully wired and tested.

## Self-Check: PASSED

Files exist:
- `telemetry/pyproject.toml` — FOUND
- `telemetry/telemetry/__init__.py` — FOUND
- `telemetry/telemetry/failure_classifier.py` — FOUND
- `telemetry/telemetry/sampler.py` — FOUND
- `telemetry/tests/conftest.py` — FOUND
- `telemetry/tests/test_failure_classifier.py` — FOUND
- `telemetry/tests/test_sampler.py` — FOUND
- `telemetry/conftest.py` — FOUND

Commits exist:
- 7db4adf — feat(13-01): package scaffold, conftest fixtures, and FailureClassifier
- 7ce9b66 — feat(13-01): GPUSampler with mock mode and JSONL append
