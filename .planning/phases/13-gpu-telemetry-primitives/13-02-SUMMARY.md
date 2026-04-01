---
phase: 13-gpu-telemetry-primitives
plan: 02
subsystem: telemetry
tags: [python, pynvml, uma-memory, anchor-store, sha256, json-persistence, tdd]

# Dependency graph
requires:
  - phase: 13-01
    provides: GPUSampler with /proc/meminfo reads and NVML mock mode

provides:
  - UMAMemModel with sample_baseline() (drop_caches + dirty baseline warning) and calculate_headroom() (5 GB jitter, UMA constraints)
  - effective_scale.compute() with multiplier tables (quant/grad/lora/seq/optimizer) and four tier thresholds
  - AnchorStore with SHA-256 config_hash (9-field HASH_FIELDS contract), 7-day expiry, atomic writes, single-record-per-hash
  - ProbeProtocol: prepare_probe() writes rollback/probe configs; evaluate_probe() returns commit/revert with strictly-positive headroom check

affects:
  - 13-03 (integration plan using all four modules)
  - telemetry package consumers (autoresearch training loop, batch scheduler)

# Tech tracking
tech-stack:
  added: [hashlib, os.replace (atomic write), datetime.fromisoformat, json JSONL]
  patterns:
    - TDD RED-GREEN-REFACTOR per module pair
    - Atomic write-to-temp-then-rename for persistent JSON stores
    - Single-record-per-hash (newest write wins) for anchor stores
    - Strict positive headroom check (>0 not >=0) for commit/revert decisions
    - Module-cache cleanup in mock_pynvml fixture to prevent test ordering pollution

key-files:
  created:
    - telemetry/telemetry/uma_model.py
    - telemetry/telemetry/effective_scale.py
    - telemetry/telemetry/anchor_store.py
    - telemetry/telemetry/probe.py
    - telemetry/tests/test_uma_model.py
    - telemetry/tests/test_effective_scale.py
    - telemetry/tests/test_anchor_store.py
    - telemetry/tests/test_probe.py
  modified:
    - telemetry/telemetry/sampler.py
    - telemetry/tests/conftest.py
    - telemetry/tests/test_uma_model.py

key-decisions:
  - "Tier classification based on raw_params not effective_params — raw model size determines hardware tier; effective_params is for memory headroom calculation"
  - "GPUSampler mock mode reads /proc/meminfo for memory (UMA architecture — memory always available via procfs, only NVML GPU metrics fall back to 0)"
  - "mock_pynvml fixture clears telemetry.sampler from sys.modules before patching pynvml to prevent test ordering pollution when other modules import sampler transitively"
  - "evaluate_probe uses strictly positive headroom (>0) for commit — zero headroom means no safety margin"
  - "HANG status produces no batch_cap key — intentional omission per TELEM-14; callers must check key existence"

patterns-established:
  - "TDD: write failing tests first (RED), implement to pass (GREEN), then refactor if needed"
  - "AnchorStore: atomic write via os.replace(tmp, final) prevents partial writes"
  - "AnchorStore: single-record-per-hash — apply_override replaces previous record"
  - "conftest mock_pynvml: clears and restores module cache to isolate pynvml mocking"

requirements-completed: [TELEM-05, TELEM-06, TELEM-07, TELEM-08, TELEM-09, TELEM-10, TELEM-11, TELEM-12]

# Metrics
duration: 35min
completed: 2026-04-01
---

# Phase 13 Plan 02: UMA Memory Model, Effective Scale, Anchor Store, and Probe Protocol Summary

**UMAMemModel + EffectiveScale + AnchorStore + ProbeProtocol — four computation modules transforming raw GPU telemetry into actionable training decisions with SHA-256 config anchors, atomic JSON persistence, and commit/revert probe evaluation**

## Performance

- **Duration:** ~35 min
- **Started:** 2026-04-01T03:30:00Z
- **Completed:** 2026-04-01T04:05:00Z
- **Tasks:** 2 (TDD)
- **Files modified:** 10

## Accomplishments

- UMAMemModel reads /proc/meminfo baseline (best-effort page cache drop with dirty baseline warning), calculates headroom with 5 GB jitter margin, UMA pin_memory=False constraint
- EffectiveScale computes effective parameter count via 5 multiplier tables; assigns tier (batch_cap/min_headroom_pct) from raw_params
- AnchorStore persists proven configs as SHA-256-keyed records with 7-day expiry, atomic write, single-record-per-hash replacement, and JSONDecodeError recovery
- ProbeProtocol writes rollback/probe configs to disk and evaluates JSONL results with strict positive headroom check for commit vs revert
- Full 47-test suite (Plan 01 + Plan 02) passes in 0.05s without GPU hardware

## Task Commits

Each task was committed atomically:

1. **Task 1: UMAMemModel and EffectiveScale (TDD)** - `894d05e` (feat)
2. **Task 2: AnchorStore and ProbeProtocol (TDD)** - `565b1b8` (feat)

## Files Created/Modified

- `telemetry/telemetry/uma_model.py` - UMAMemModel: sample_baseline(), calculate_headroom()
- `telemetry/telemetry/effective_scale.py` - compute() with QUANT/GRAD/LoRA/seq/optimizer multipliers and TIERS
- `telemetry/telemetry/anchor_store.py` - AnchorStore with HASH_FIELDS, EXPIRY_DAYS=7, apply_override, atomic _save()
- `telemetry/telemetry/probe.py` - prepare_probe() and evaluate_probe() with strict headroom check
- `telemetry/tests/test_uma_model.py` - 6 tests covering baseline, drop_caches warning, headroom calculation
- `telemetry/tests/test_effective_scale.py` - 7 tests covering all four tiers and multiplier tables
- `telemetry/tests/test_anchor_store.py` - 13 tests covering hash contract, expiry, override rules, persistence, atomic write, corruption recovery
- `telemetry/tests/test_probe.py` - 7 tests covering prepare, rollback/probe content, commit/revert, exact threshold boundary
- `telemetry/telemetry/sampler.py` - Bug fix: mock mode now reads /proc/meminfo for memory (UMA architecture)
- `telemetry/tests/conftest.py` - Bug fix: mock_pynvml clears/restores cached modules to prevent test ordering pollution

## Decisions Made

- **Tier classification on raw_params:** The plan's test `test_tier_1_13b` uses `raw_params=7B` with `fp16` multiplier (2.0) and expects `batch_cap=16` (1-13B tier). With fp16, effective=14B which falls in 13-30B tier. Resolved by classifying tier on `raw_params` — raw model size determines hardware requirements; effective_params is used for memory headroom, not tier assignment.
- **GPUSampler mock mode reads /proc/meminfo:** In UMA architecture, memory is always available from /proc/meminfo even without NVML. The original mock mode returned hardcoded 0.0 for memory, but UMAMemModel tests require 80.0 GB from mock_meminfo. Fixed sampler to read meminfo even in mock mode.
- **conftest module cache cleanup:** test_uma_model.py imports `telemetry.sampler` which caches it in sys.modules with real pynvml. When test_sampler.py runs later with mock_pynvml, the cached module has real pynvml bound. Fixed by having mock_pynvml fixture clear and restore telemetry module cache.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] GPUSampler mock mode read hardcoded 0.0 for memory instead of /proc/meminfo**
- **Found during:** Task 1 (UMAMemModel GREEN phase) — test_sample_baseline expected 80.0 GB from mock_meminfo but got 0.0
- **Issue:** In mock mode, `sample()` returned hardcoded `"mem_available_gb": 0.0` without reading /proc/meminfo. On UMA architecture, /proc/meminfo is always authoritative for memory regardless of NVML availability.
- **Fix:** Updated mock mode branch to call `self._read_meminfo("MemAvailable")` and `self._read_meminfo("Cached")` instead of returning 0.0
- **Files modified:** `telemetry/telemetry/sampler.py`
- **Verification:** All Plan 01 sampler tests still pass; UMAMemModel tests now read 80.0 GB from mock_meminfo
- **Committed in:** `894d05e` (Task 1 commit)

**2. [Rule 1 - Bug] Test ordering pollution: cached telemetry.sampler with real pynvml broke mock_pynvml isolation**
- **Found during:** Task 2 (full suite run) — test_anchor_store.py imports telemetry modules transitively, caching real pynvml in sampler; test_sampler.py mock tests then fail because mock_pynvml patches sys.modules["pynvml"] but the cached module has the real pynvml object bound
- **Issue:** mock_pynvml fixture uses `patch.dict(sys.modules, {"pynvml": mock_mod})` but doesn't clear `telemetry.sampler` from sys.modules, so the cached module continues using real pynvml
- **Fix:** Updated mock_pynvml fixture in conftest.py to snapshot/clear/restore `telemetry.sampler` and `telemetry.uma_model` from sys.modules. Also updated test_uma_model.py to delete module cache in finally blocks after patching `_MEMINFO_PATH`.
- **Files modified:** `telemetry/tests/conftest.py`, `telemetry/tests/test_uma_model.py`
- **Verification:** 47/47 tests pass in any test ordering
- **Committed in:** `565b1b8` (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (both Rule 1 bugs)
**Impact on plan:** Both fixes were required for correctness. The sampler mock mode fix aligns with UMA architecture semantics. The conftest fix is a standard test isolation pattern for module-patching scenarios.

## Issues Encountered

- `patch.object(Path_instance, "write_text")` fails with `AttributeError: 'PosixPath' object attribute 'write_text' is read-only` — patched `_DROP_CACHES_PATH` module attribute with a `MagicMock(spec=Path)` instead.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- All four Plan 02 modules fully implemented and tested: UMAMemModel, EffectiveScale, AnchorStore, ProbeProtocol
- Module import chain verified: `from telemetry.anchor_store import AnchorStore, HASH_FIELDS` and all others import cleanly
- Plan 03 (integration) can proceed: probe.py uses uma_model; anchor_store receives results; effective_scale computes tiers; GPUSampler reads hardware

---
*Phase: 13-gpu-telemetry-primitives*
*Completed: 2026-04-01*
