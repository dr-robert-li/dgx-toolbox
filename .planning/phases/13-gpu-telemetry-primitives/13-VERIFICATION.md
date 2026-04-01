---
phase: 13-gpu-telemetry-primitives
verified: 2026-04-01T00:00:00Z
status: gaps_found
score: 15/17 must-haves verified
gaps:
  - truth: "GPUSampler degrades gracefully when individual NVML metric reads fail after successful init — returns None for failed metrics, never crashes"
    status: failed
    reason: "sampler.py sample() has no per-metric try/except blocks. Lines 83-88 call nvmlDeviceGetPowerUsage, nvmlDeviceGetTemperature, and nvmlDeviceGetUtilizationRates without individual NVMLError handlers. If NVML init succeeds but any subsequent metric call raises NVMLError, sample() will crash instead of returning None for the failed metric and continuing."
    artifacts:
      - path: "telemetry/telemetry/sampler.py"
        issue: "Lines 83-88: three NVML calls (nvmlDeviceGetPowerUsage, nvmlDeviceGetTemperature, nvmlDeviceGetUtilizationRates) have no individual try/except pynvml.NVMLError handlers. Plan 01 explicitly required per-metric try/except for graceful partial failure. Plan 01 acceptance criteria item 6 of sampler.py: 'contains per-metric except pynvml.NVMLError blocks (at least 3 separate try/except for watts, temperature, utilization)'."
      - path: "telemetry/tests/test_sampler.py"
        issue: "Six required tests are absent: test_partial_nvml_power_failure, test_partial_nvml_temp_failure, test_partial_nvml_util_failure, test_meminfo_missing_key, test_meminfo_permission_denied, test_sample_always_returns_all_keys. Plan 01 task 2 behavior block mandated all six. Plan 01 acceptance criteria items 7-9 of test_sampler.py require them explicitly."
    missing:
      - "In telemetry/telemetry/sampler.py sample() live-mode path: wrap each of the three NVML calls in its own try/except pynvml.NVMLError block that sets the metric to None on failure"
      - "In telemetry/tests/test_sampler.py: add test_partial_nvml_power_failure (NVML init succeeds, nvmlDeviceGetPowerUsage raises NVMLError, watts=None other fields populated)"
      - "In telemetry/tests/test_sampler.py: add test_partial_nvml_temp_failure (nvmlDeviceGetTemperature raises, temperature_c=None)"
      - "In telemetry/tests/test_sampler.py: add test_partial_nvml_util_failure (nvmlDeviceGetUtilizationRates raises, gpu_util_pct=None)"
      - "In telemetry/tests/test_sampler.py: add test_meminfo_missing_key (_read_meminfo('NonexistentKey') returns 0.0)"
      - "In telemetry/tests/test_sampler.py: add test_meminfo_permission_denied (patch _MEMINFO_PATH.read_text to raise PermissionError, _read_meminfo returns 0.0)"
      - "In telemetry/tests/test_sampler.py: add test_sample_always_returns_all_keys (under partial failure, all 6 keys always present, values may be None)"
human_verification:
  - test: "Run bash status.sh and inspect GPU TELEMETRY section formatting"
    expected: "Section header 'GPU TELEMETRY' followed by either mock values with labels (Watts, Temperature, Utilization, MemAvailable), 'sampler not installed', or 'sampling failed' — correctly indented and aligned"
    why_human: "Visual formatting of shell output requires human inspection; automated checks confirm only the presence of the relevant strings"
---

# Phase 13: GPU Telemetry Primitives Verification Report

**Phase Goal:** Any project training on DGX Spark can import the telemetry package to sample hardware state, calculate UMA memory headroom, classify failures, and anchor proven batch configurations — without implementing any NVML or /proc calls themselves
**Verified:** 2026-04-01T00:00:00Z
**Status:** gaps_found
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| #  | Truth | Status | Evidence |
|----|-------|--------|---------|
| 1  | A caller can pip install -e dgx-toolbox/telemetry/ and import GPUSampler without error | VERIFIED | telemetry/pyproject.toml exists with name="dgx-telemetry"; all imports confirmed working: `python -c "from telemetry.sampler import GPUSampler; ..."` exits 0 |
| 2  | GPUSampler.sample() returns a dict with watts, temperature_c, gpu_util_pct, mem_available_gb, page_cache_gb, mock fields | VERIFIED | sampler.py lines 74-98 return all 6 keys in both mock and live paths; test_sample_returns_all_fields passes |
| 3  | GPUSampler works in mock mode when no GPU hardware is present | VERIFIED | sampler.py __init__ lines 42-46 catch NVMLError and set _mock=True; 52 tests pass without GPU hardware |
| 4  | GPUSampler degrades gracefully when individual NVML metric reads fail after successful init — returns None for failed metrics, never crashes | FAILED | sampler.py lines 83-88 have no per-metric try/except. All three NVML calls (nvmlDeviceGetPowerUsage, nvmlDeviceGetTemperature, nvmlDeviceGetUtilizationRates) are bare — if NVML init succeeds but a metric call raises, sample() crashes. Six corresponding tests missing from test_sampler.py. |
| 5  | append_jsonl() writes valid NDJSON records to a file | VERIFIED | sampler.py lines 127-137; test_append_jsonl confirms 2 calls produce 2 valid JSON lines each with ts key |
| 6  | classify_failure() correctly classifies clean, oom, hang, thermal, pressure outcomes | VERIFIED | failure_classifier.py lines 27-65; all 7 test_failure_classifier tests pass |
| 7  | HANG classification never contains a batch_cap key | VERIFIED | failure_classifier.py line 44-55 returns hang dict with no batch_cap; test_hang_no_batch_cap asserts "batch_cap" not in result |
| 8  | sample_baseline() returns a baseline dict with MemAvailable, Cached, idle watts, and timestamp | VERIFIED | uma_model.py lines 24-51; test_sample_baseline passes |
| 9  | sample_baseline() logs a warning when drop_caches fails, indicating baseline may include cached pages (dirty baseline) | VERIFIED | uma_model.py lines 37-43 log.warning with "dirty baseline" string; test_sample_baseline_drop_caches_logs_warning passes |
| 10 | calculate_headroom() returns safe_threshold accounting for 5 GB jitter margin | VERIFIED | uma_model.py lines 70-79; test_calculate_headroom_default_jitter passes (safe_threshold = baseline*pct/100 + 5.0) |
| 11 | effective_scale.compute() returns effective_params and correct tier dict for all four tier ranges | VERIFIED | effective_scale.py TIERS list lines 55-60; all 7 tier/multiplier tests pass |
| 12 | AnchorStore persists records keyed by config_hash (SHA-256 of exactly 9 fields) and expires after 7 days | VERIFIED | anchor_store.py HASH_FIELDS (9 fields locked), EXPIRY_DAYS=7, _is_expired method; 13 anchor store tests pass |
| 13 | AnchorStore uses single-record-per-hash (newest write wins) | VERIFIED | anchor_store.py line 123: self._records[config_hash] = record replaces; test_single_record_per_hash passes |
| 14 | AnchorStore writes use atomic temp-file-then-rename pattern | VERIFIED | anchor_store.py _save() lines 149-155 use os.replace(tmp_path, self._store_path); test_atomic_write_survives_crash passes |
| 15 | COMPLETED anchor raises ceiling; OOM/WATCHDOG sets hard cap; HANG logs only with no batch_cap | VERIFIED | anchor_store.py lines 116-120 implement all three rules; test_completed_raises_ceiling, test_oom_sets_hard_cap, test_watchdog_sets_hard_cap, test_hang_no_batch_cap all pass |
| 16 | prepare_probe() writes rollback and probe configs to disk and returns path dict | VERIFIED | probe.py lines 18-57; test_prepare_probe, test_prepare_probe_rollback_content, test_prepare_probe_probe_content all pass |
| 17 | evaluate_probe() returns commit or revert action with anchor_record | VERIFIED | probe.py lines 60-134 with strictly positive headroom requirement; all 4 probe evaluation tests pass |
| 18 | dgx_toolbox.py status_report() includes gpu_telemetry section when telemetry package is importable and sampling succeeds | VERIFIED | dgx_toolbox.py lines 547-576; try/except Exception pattern; conditional include; 5 bridge tests pass |
| 19 | dgx_toolbox.py status_report() omits gpu_telemetry section gracefully on import failure or runtime exception | VERIFIED | dgx_toolbox.py line 555: except Exception: pass; test_status_report_without_telemetry and test_status_report_sampling_exception both pass |
| 20 | status.sh displays GPU TELEMETRY block with mode-conditional output | VERIFIED | status.sh lines 86-109; "GPU TELEMETRY", import guard, "sampler not installed", "sampling failed" all present |

**Score:** 15/17 plan truths verified (truth #4 failed; human verification needed for status.sh formatting)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `telemetry/pyproject.toml` | Package definition with nvidia-ml-py dependency | VERIFIED | name="dgx-telemetry", "nvidia-ml-py>=13.595,<14"; no pynvml |
| `telemetry/telemetry/__init__.py` | Package init with version | VERIFIED | __version__ = "0.1.0" |
| `telemetry/telemetry/sampler.py` | GPUSampler class with sample() and append_jsonl() | STUB (partial) | Class exists, mock mode correct, JSONL works, BUT live-mode sample() lacks per-metric NVMLError handling |
| `telemetry/telemetry/failure_classifier.py` | classify_failure() function | VERIFIED | All 5 classifications correct; HANG has no batch_cap |
| `telemetry/tests/conftest.py` | Shared mock_pynvml fixture | VERIFIED | mock_pynvml and mock_meminfo both present; correctly clears module cache |
| `telemetry/telemetry/uma_model.py` | UMAMemModel with sample_baseline() and calculate_headroom() | VERIFIED | pin_memory=False, prefetch_factor=4, dirty baseline warning |
| `telemetry/telemetry/effective_scale.py` | compute() with multiplier tables and tier thresholds | VERIFIED | All 4 tiers, 5 multiplier tables, correct tier selection |
| `telemetry/telemetry/anchor_store.py` | AnchorStore with JSON persistence, HASH_FIELDS, override rules | VERIFIED | HASH_FIELDS locked 9-field contract, EXPIRY_DAYS=7, atomic writes, JSONDecodeError recovery |
| `telemetry/telemetry/probe.py` | prepare_probe() and evaluate_probe() | VERIFIED | Strictly positive headroom required; evaluate_probe uses UMAMemModel.calculate_headroom |
| `examples/dgx_toolbox.py` | gpu_telemetry section in status_report() | VERIFIED | try/except Exception (not ImportError); conditional inclusion when non-None |
| `status.sh` | GPU TELEMETRY conditional block | VERIFIED | Three-mode handling: working, sampler not installed, sampling failed |
| `telemetry/tests/test_dgx_toolbox_bridge.py` | Bridge tests including three modes | VERIFIED | 5 tests covering all required bridge modes |
| `telemetry/tests/test_sampler.py` | Full sampler test coverage | STUB (partial) | 7 of 13 required tests present; 6 partial-failure tests missing |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `telemetry/telemetry/sampler.py` | `pynvml` | import pynvml with NVMLError fallback to mock mode | VERIFIED | line 19: `import pynvml`; line 45: `except pynvml.NVMLError` in __init__ |
| `telemetry/telemetry/sampler.py` | `/proc/meminfo` | _read_meminfo reads MemAvailable and Cached | VERIFIED | lines 111-125; _MEMINFO_PATH = Path("/proc/meminfo") at module level |
| `telemetry/telemetry/uma_model.py` | `telemetry/telemetry/sampler.py` | from telemetry.sampler import GPUSampler | VERIFIED | uma_model.py line 13 |
| `telemetry/telemetry/probe.py` | `telemetry/telemetry/uma_model.py` | evaluate_probe calls calculate_headroom | VERIFIED | probe.py line 105: UMAMemModel.calculate_headroom() |
| `telemetry/telemetry/probe.py` | `telemetry/telemetry/anchor_store.py` | evaluate_probe creates anchor_record | VERIFIED | probe.py lines 119-124 produce anchor_record dict |
| `telemetry/telemetry/anchor_store.py` | `telemetry/telemetry/effective_scale.py` | apply_override receives tier_cap | VERIFIED | apply_override signature has tier_cap parameter; callers compute via effective_scale.compute |
| `examples/dgx_toolbox.py` | `telemetry/telemetry/sampler.py` | try: from telemetry.sampler import GPUSampler | VERIFIED | dgx_toolbox.py line 552 |
| `status.sh` | `telemetry/telemetry/sampler.py` | python3 -c import guard | VERIFIED | status.sh line 87 |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|--------------|--------|--------------------|--------|
| `sampler.py sample()` mock path | watts=0.0, mem_available_gb=_read_meminfo() | /proc/meminfo for memory | Yes (/proc is live) | FLOWING |
| `sampler.py sample()` live path | watts, temperature_c, gpu_util_pct | pynvml NVML calls (no per-metric guard) | Yes when NVML succeeds, crashes on partial failure | PARTIAL |
| `uma_model.py sample_baseline()` | snapshot from GPUSampler | sampler.sample() | Yes (delegates to sampler) | FLOWING |
| `probe.py evaluate_probe()` | min_mem from JSONL lines | results_path file | Yes (reads actual file) | FLOWING |
| `anchor_store.py _save()` | self._records | in-memory dict written atomically | Yes (atomic os.replace) | FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| All 52 tests pass | `cd telemetry && python -m pytest tests/ -q` | 52 passed in 0.05s | PASS |
| All modules import | `python -c "from telemetry.sampler import GPUSampler; from telemetry.anchor_store import AnchorStore, HASH_FIELDS; print('OK')"` | OK; HASH_FIELDS=[9 fields] | PASS |
| No subprocess in telemetry modules | grep subprocess telemetry/telemetry/*.py | Only docstring comment in sampler.py | PASS |
| nvmlDeviceGetMemoryInfo never called | grep nvmlDeviceGetMemoryInfo telemetry/telemetry/*.py | Not found | PASS |
| status.sh GPU TELEMETRY section present | grep "GPU TELEMETRY" status.sh | Line 86: echo "GPU TELEMETRY" | PASS |
| Per-metric NVML degradation | grep -c "except pynvml.NVMLError" telemetry/telemetry/sampler.py | 1 (only in __init__, none in sample()) | FAIL |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|---------|
| TELEM-01 | Plan 01 | Import GPUSampler; structured dict; no subprocess; /proc/meminfo for memory | PARTIAL | Import works; dict correct; no subprocess. BUT: per-metric NVML degradation absent — individual metric read failures in live mode crash sample() |
| TELEM-02 | Plan 01 | pynvml for GPU metrics; /proc/meminfo for memory; nvmlDeviceGetMemoryInfo never called | VERIFIED | nvmlDeviceGetMemoryInfo absent from codebase; _MEMINFO_PATH used; UMA pattern implemented |
| TELEM-03 | Plan 01 | sample() returns complete snapshot; append_jsonl() appends NDJSON | VERIFIED | Both methods implemented and tested |
| TELEM-04 | Plan 01 | Mock mode without GPU hardware | VERIFIED | NVMLError in __init__ triggers mock=True; all 52 tests pass in CI |
| TELEM-05 | Plan 02 | sample_baseline() drops page cache; returns baseline dict with 4 keys | VERIFIED | _DROP_CACHES_PATH.write_text("3") with PermissionError handling; all 3 uma_model tests pass |
| TELEM-06 | Plan 02 | calculate_headroom() with 5 GB jitter; pin_memory=False; prefetch_factor<=4 | VERIFIED | uma_model.py lines 68-79; pin_memory=False; prefetch_factor=4 |
| TELEM-07 | Plan 02 | effective_scale.compute() with multiplier tables | VERIFIED | 5 multiplier tables; 7 tests pass |
| TELEM-08 | Plan 02 | Correct tier thresholds: <=1B/1-13B/13-30B/30B+ | VERIFIED | TIERS list with 4 entries; all 4 tier tests pass |
| TELEM-09 | Plan 02 | AnchorStore with SHA-256 config_hash (9 fields); 7-day expiry | VERIFIED | HASH_FIELDS=[9 fields] with PERMANENT CONTRACT comment; EXPIRY_DAYS=7; 13 tests pass |
| TELEM-10 | Plan 02 | Override rules: COMPLETED raises ceiling; OOM/WATCHDOG hard cap; HANG logs only | VERIFIED | apply_override implements all 3 rules; 4 corresponding tests pass; HANG has no batch_cap |
| TELEM-11 | Plan 02 | prepare_probe() writes rollback and probe configs; returns 3 paths | VERIFIED | probe.py lines 18-57; 3 prepare_probe tests pass |
| TELEM-12 | Plan 02 | evaluate_probe() reads results; returns commit/revert with anchor_record | VERIFIED | strictly positive headroom; 4 evaluation tests pass |
| TELEM-13 | Plan 01 | classify_failure() classifies 5 outcomes | VERIFIED | All 5 classifications correct; 7 tests pass |
| TELEM-14 | Plan 01 | HANG never produces batch_cap | VERIFIED | failure_classifier.py comment "No batch_cap key — intentional (TELEM-14)"; anchor_store.py HANG branch has no batch_cap; 2 tests verify this in separate modules |
| TELEM-15 | Plan 01 | pyproject.toml; pip install -e; Python 3.10+; aarch64 safe | VERIFIED | pyproject.toml exists; nvidia-ml-py is pure Python wheel (aarch64 safe); requires-python=">=3.10"; editable install confirmed working |
| TELEM-16 | Plan 03 | dgx_toolbox.py status_report() includes/omits gpu_telemetry section | VERIFIED | try/except Exception pattern; conditional include via `if gpu_telemetry is not None`; 5 bridge tests pass |
| TELEM-17 | Plan 03 | status.sh GPU TELEMETRY section; "sampler not installed" fallback | VERIFIED | All three modes present in status.sh lines 86-109 |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `telemetry/telemetry/sampler.py` | 83-88 | Three bare NVML calls in live sample() path with no per-metric try/except | Blocker | Partial NVML failure (e.g., power reading unsupported on some hardware) causes sample() to crash entirely rather than returning None for that metric. On DGX Spark GB10, individual NVML readings can raise NVMLError_NotSupported while the device is otherwise accessible. This makes live-mode sampling fragile. |

### Human Verification Required

#### 1. status.sh GPU TELEMETRY Output Formatting

**Test:** Run `bash /home/robert_li/dgx-toolbox/status.sh 2>&1 | grep -A10 "GPU TELEMETRY"` in the project directory
**Expected:** Correctly indented output with either mock values (Mode: mock, Watts: 0.0, Temperature: 0, Utilization: 0) or real GPU values, formatted with label/value alignment; "sampler not installed" if the package is not on PYTHONPATH
**Why human:** Visual alignment and indentation quality requires human inspection; automated grep only confirms string presence not formatting quality

### Gaps Summary

**One gap blocks full goal achievement:**

**sampler.py live-mode partial NVML failure degradation (affects TELEM-01):**
The `sample()` method in live mode (non-mock) calls three NVML functions — `nvmlDeviceGetPowerUsage`, `nvmlDeviceGetTemperature`, and `nvmlDeviceGetUtilizationRates` — without any per-metric exception handling. If NVML initializes successfully but any of these subsequent calls raises `pynvml.NVMLError` (e.g., `NVMLError_NotSupported` for power on certain hardware revisions), the entire `sample()` call crashes with an unhandled exception. The plan explicitly required per-metric degradation as a response to Codex/Gemini code review concerns, and the acceptance criteria for `sampler.py` explicitly listed "contains per-metric except pynvml.NVMLError blocks (at least 3 separate try/except)". The implementation was delivered without this safeguard, and the six required tests that would have caught this omission were also never written.

This is a real-world risk on DGX Spark: on GB10 hardware, specific NVML metric reads can return `NVMLError_NotSupported` while the device is otherwise functional. Without per-metric guards, a single unsupported metric query can disable telemetry entirely for a running training job.

The fix is straightforward: wrap each of the three NVML calls in `sample()` in their own `try/except pynvml.NVMLError: pass` block (defaulting to None), and add the six missing tests to `test_sampler.py`.

---

_Verified: 2026-04-01T00:00:00Z_
_Verifier: Claude (gsd-verifier)_
