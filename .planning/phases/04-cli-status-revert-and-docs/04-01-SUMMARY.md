---
phase: 04-cli-status-revert-and-docs
plan: 01
subsystem: cli
tags: [bash, modelstore, status, revert, tdd, interrupt-safe, op-state]

# Dependency graph
requires:
  - phase: 03-migration-recall-and-safety
    provides: hf_recall_model/ollama_recall_model adapters, op_state.json pattern, audit_log, check_cold_mounted
  - phase: 02-adapters-and-usage-tracking
    provides: hf_adapter.sh, ollama_adapter.sh, usage.json, watcher PID pattern
  - phase: 01-foundation-and-init
    provides: common.sh, config.sh, modelstore.sh dispatcher

provides:
  - modelstore status command: model table (HOT/COLD/BROKEN tiers) + system dashboard
  - modelstore revert command: interrupt-safe full revert with --force, preview, completed_models tracking
  - test/test-status.sh: 10 automated tests for status output
  - test/test-revert.sh: 12 automated tests for revert flow
  - Dispatcher wiring confirmed: status, revert, migrate, recall all routed in modelstore.sh

affects: [04-02-PLAN, docs-phase, any future cmd/ additions]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - TDD red-green for bash scripts: test file before implementation
    - find -maxdepth 1 instead of glob with / to detect broken symlinks
    - Mock lib injection: create mock_cmd/revert.sh with real lib sources + inline override
    - completed_models JSON array in op_state.json for interrupt-safe multi-model operations
    - _init_revert_state / _append_completed / _is_completed helpers for tracking progress

key-files:
  created:
    - modelstore/cmd/status.sh
    - modelstore/cmd/revert.sh
    - modelstore/test/test-status.sh
    - modelstore/test/test-revert.sh
  modified:
    - modelstore/test/run-all.sh

key-decisions:
  - "status.sh scans HOT_HF_PATH with find -maxdepth 1 (not hf_list_models Python API) to show all tiers including BROKEN dangling symlinks"
  - "test-revert.sh uses mock_cmd wrapper: recreates revert.sh header with real lib sources + inline check_cold_mounted override, then appends real revert body via tail -n +21"
  - "Bash glob with trailing / does not match broken symlinks; find -maxdepth 1 is required to enumerate all model entries"
  - "revert.sh completed_models uses jq .completed_models array in op_state.json for per-model interrupt-safe tracking, unlike migrate.sh single-model state"

requirements-completed: [CLI-01, CLI-03, CLI-04, CLI-05, CLI-07]

# Metrics
duration: 10min
completed: 2026-03-22
---

# Phase 4 Plan 1: Status and Revert Commands Summary

**modelstore status dashboard (HOT/COLD/BROKEN model table + system health) and interrupt-safe revert with completed_models tracking, --force, preview, and full cleanup**

## Performance

- **Duration:** 10 min
- **Started:** 2026-03-21T21:58:08Z
- **Completed:** 2026-03-22T22:08:00Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments

- status.sh prints 6-column model table (MODEL, ECOSYSTEM, TIER, SIZE, LAST USED, DAYS LEFT) sorted by size, with HOT/COLD/BROKEN tier detection via `find -maxdepth 1`
- status.sh dashboard shows drive totals (df -BG), model counts, watcher/cron status, and last migration timestamp
- revert.sh supports --force, interactive preview+confirm, interrupt-safe resume via completed_models in op_state.json
- revert.sh handles cold-drive mount check, conflicting op detection (abort fresh, clear stale), and full cleanup (cron/watcher/cold dirs) while preserving config.json
- All 10 status tests and 12 revert tests pass; full suite (run-all.sh) passes

## Task Commits

1. **Task 1: status.sh and test-status.sh** - `1db5e6c` (feat)
2. **Task 2: revert.sh, test-revert.sh, run-all.sh** - `6565f11` (feat)

**Plan metadata:** (docs commit follows)

## Files Created/Modified

- `modelstore/cmd/status.sh` - Model table with HOT/COLD/BROKEN tiers, dashboard summary with drive totals/watcher/cron/last-migration
- `modelstore/cmd/revert.sh` - Interrupt-safe full revert: --force, preview, completed_models tracking, cleanup phases
- `modelstore/test/test-status.sh` - 10 tests: STAT-01 through STAT-10 (header, tiers, dashboard sections, Ollama graceful failure)
- `modelstore/test/test-revert.sh` - 12 tests: REVT-01 through REVT-12 (recalls, cleanup, resume, abort cases)
- `modelstore/test/run-all.sh` - Added test-status.sh and test-revert.sh to suite

## Decisions Made

- **status.sh uses find, not hf_list_models:** Python's `scan_cache_dir()` scans the system HF cache, not the configurable HOT_HF_PATH. `find -maxdepth 1 -name "models--*"` gives full control and also picks up broken symlinks (bash glob with trailing `/` skips them).
- **test-revert.sh mock wrapper pattern:** `check_cold_mounted` from `common.sh` uses `mountpoint -q` which fails in temp test dirs. Solution: create a `mock_cmd/revert.sh` that sources real libs then redefines `check_cold_mounted`, then appends revert.sh body via `tail -n +21`.
- **completed_models array vs single-model state:** migrate.sh tracks one model at a time. Revert needs multi-model tracking across resumption, so `op_state.json` carries a `completed_models` array with `_append_completed()` and `_is_completed()` helpers.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] bash glob with trailing / skips broken symlinks in status model scan**
- **Found during:** Task 1 (status.sh GREEN phase)
- **Issue:** Initial implementation used `for model_dir in "${HOT_HF_PATH}"/models--*/` which bash expands to only existing directories/valid symlinks, missing dangling symlinks (BROKEN tier)
- **Fix:** Changed to `find "${HOT_HF_PATH}" -maxdepth 1 -name "models--*"` which enumerates all filesystem entries regardless of symlink validity
- **Files modified:** modelstore/cmd/status.sh
- **Verification:** STAT-04 test passes (BROKEN tier shows for dangling symlink)
- **Committed in:** 1db5e6c

**2. [Rule 1 - Bug] hf_list_models Python API uses system cache, not HOT_HF_PATH**
- **Found during:** Task 1 (status.sh GREEN phase)
- **Issue:** `hf_list_models` primary path uses `huggingface_hub.scan_cache_dir()` which scans the real system HF cache, not the configurable `HOT_HF_PATH` used in tests and non-default installs
- **Fix:** Replaced `hf_list_models` call with direct `find` scan of `HOT_HF_PATH`
- **Files modified:** modelstore/cmd/status.sh
- **Verification:** Test models in temp dir are detected correctly; STAT-02/03/04 pass
- **Committed in:** 1db5e6c

---

**Total deviations:** 2 auto-fixed (Rule 1 bugs)
**Impact on plan:** Both fixes improve correctness and test reliability. Status command is more robust for non-standard HF cache paths.

## Issues Encountered

- test-revert.sh mock setup required 3 iterations to find a pattern that (a) overrides `check_cold_mounted` after `common.sh` is sourced and (b) correctly handles the `BASH_SOURCE`-relative path to `lib.sh`. Final solution: generate `mock_cmd/revert.sh` programmatically with inline override + `tail -n +21` for the body.

## Next Phase Readiness

- Phase 4 Plan 2 (docs/man pages) can proceed: all CLI commands now exist
- modelstore.sh dispatcher routing confirmed for all 5 subcommands
- Full test suite passes including new status and revert tests

---
*Phase: 04-cli-status-revert-and-docs*
*Completed: 2026-03-22*

## Self-Check: PASSED

- FOUND: modelstore/cmd/status.sh
- FOUND: modelstore/cmd/revert.sh
- FOUND: modelstore/test/test-status.sh
- FOUND: modelstore/test/test-revert.sh
- FOUND: .planning/phases/04-cli-status-revert-and-docs/04-01-SUMMARY.md
- FOUND commit: 1db5e6c
- FOUND commit: 6565f11
