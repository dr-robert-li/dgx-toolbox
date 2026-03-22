---
phase: 05-gateway-and-trace-foundation
plan: 03
subsystem: testing
tags: [nemoguardrails, presidio, spacy, aarch64, compatibility, validation]

# Dependency graph
requires:
  - phase: 05-gateway-and-trace-foundation
    provides: harness/ Python package structure, pyproject.toml, guards/ directory slot

provides:
  - aarch64 NeMo Guardrails compatibility probe script (validate_aarch64.sh)
  - NeMo Guardrails importability check module (nemo_compat.py)
  - Presidio AnalyzerEngine functional check
  - Smoke tests with graceful skip behavior when libraries not installed

affects:
  - 06-input-output-guardrails — go/no-go gate: only proceed if aarch64 pass confirmed
  - 07-constitutional-ai-critique — depends on NeMo Guardrails being confirmed working on hardware

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Graceful skip pattern: pytest.skip() when optional library not installed (vs fail)"
    - "importlib.import_module() for soft dependency probing"
    - "check_* function pattern returning typed dict (available, error) for compatibility probes"

key-files:
  created:
    - harness/guards/__init__.py
    - harness/guards/nemo_compat.py
    - harness/scripts/validate_aarch64.sh
    - harness/tests/test_nemo_compat.py
  modified: []

key-decisions:
  - "Use importlib.import_module() for NeMo probe (avoids top-level ImportError in environments without nemoguardrails)"
  - "Tests skip gracefully instead of failing when library not installed — safe in CI without aarch64 hardware"
  - "validate_aarch64.sh uses set -euo pipefail and tee /tmp/nemo-install.log for failure diagnostics"
  - "7-step probe covers: arch check, build tools, venv creation, nemoguardrails install, import validation, Presidio+spaCy install, entity detection"

patterns-established:
  - "Compatibility probe: check_*_available() returns dict with available/version/error keys"
  - "Hardware-gated tests: pytest.skip() with skip reason when library unavailable"

requirements-completed: []

# Metrics
duration: 10min
completed: 2026-03-22
---

# Phase 5 Plan 3: NeMo Guardrails aarch64 Validation Summary

**aarch64 compatibility probe script and NeMo/Presidio importability checks for DGX Spark go/no-go gate**

## Performance

- **Duration:** ~10 min
- **Started:** 2026-03-22T02:27:00Z
- **Completed:** 2026-03-22T02:37:12Z
- **Tasks:** 1 of 2 (Task 2 is human-verify checkpoint — awaiting DGX Spark confirmation)
- **Files modified:** 4

## Accomplishments
- Created 7-step validation script that installs NeMo Guardrails (Annoy C++ build), validates LLMRails import, and tests Presidio entity detection end-to-end
- Created `harness/guards/nemo_compat.py` with soft-dependency probe functions that return structured results instead of raising
- Created `harness/guards/__init__.py` exporting both check functions for use in Phase 6+ integration
- Created smoke tests with graceful skip when libraries not installed — confirmed: Presidio PASS, NeMo skip (not installed in dev env), both dict-shape tests PASS

## Task Commits

Each task was committed atomically:

1. **Task 1: Create aarch64 validation script and NeMo compatibility module** - `db20414` (feat)

**Plan metadata:** TBD (docs: complete plan — will be added after Task 2 checkpoint resolved)

## Files Created/Modified
- `harness/guards/__init__.py` - Exports check_nemo_available and check_presidio_available
- `harness/guards/nemo_compat.py` - Soft-probe functions for NeMo and Presidio availability
- `harness/scripts/validate_aarch64.sh` - 7-step aarch64 compatibility probe, chmod +x
- `harness/tests/test_nemo_compat.py` - 4 smoke tests (2 hardware-gated skip, 2 always pass)

## Decisions Made
- Used `importlib.import_module("nemoguardrails")` instead of direct import to avoid top-level ImportError in dev environments without the library installed
- Tests use `pytest.skip()` (not `pytest.fail()`) when library unavailable — enables safe CI runs without aarch64 hardware
- Probe script outputs structured PASS/FAIL lines for each component to ease failure diagnosis
- Script `tee`s nemoguardrails install to `/tmp/nemo-install.log` for post-failure diagnosis

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
- None. Tests ran immediately: 3 passed (Presidio installed in dev env), 1 skipped (nemoguardrails not in dev env), 0 failed.

## User Setup Required

**Task 2 requires manual hardware verification.** User must SSH to DGX Spark and run:

```bash
bash harness/scripts/validate_aarch64.sh /tmp/harness-compat-test
```

Expected ending output:
```
[7/7] === RESULTS ===
  NeMo Guardrails: PASS
  Annoy (C++ build): PASS
  Presidio + spaCy NER: PASS
  Architecture: aarch64
```

After running, reply with "aarch64 pass" or "aarch64 fail: [error details]".

## Next Phase Readiness
- Task 2 (human checkpoint) must be completed before Phase 6 can begin
- If aarch64 PASS: Phase 6 can proceed with full NeMo Guardrails implementation
- If aarch64 FAIL: Phase 6 planner must select an alternative guardrails approach

---
*Phase: 05-gateway-and-trace-foundation*
*Completed: 2026-03-22 (partial — Task 2 awaiting hardware verification)*
