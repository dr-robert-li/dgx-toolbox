---
phase: 10-hitl-dashboard
plan: 02
subsystem: hitl
tags: [calibration, jsonl, fine-tuning, cli, argparse, tdd]

# Dependency graph
requires:
  - phase: 10-01
    provides: TraceStore.write_correction, query_corrections, query_by_id, corrections schema
  - phase: 07-03
    provides: _resolve_since helper in harness/proxy/admin.py

provides:
  - compute_calibration() function in harness/hitl/calibrate.py with MIN_CORRECTIONS=5 guard
  - export_jsonl() function in harness/hitl/export.py producing OpenAI-format JSONL
  - CLI entry point harness/hitl/__main__.py with calibrate, export, ui subcommands

affects: [HITL-03, fine-tuning pipelines, threshold management]

# Tech tracking
tech-stack:
  added: []
  patterns: [TDD red-green, eval/__main__.py CLI pattern, OpenAI JSONL format]

key-files:
  created:
    - harness/hitl/calibrate.py
    - harness/hitl/export.py
  modified:
    - harness/hitl/__main__.py
    - harness/tests/test_hitl.py

key-decisions:
  - "compute_calibration uses midpoint strategy when both approved and rejected scores exist; P95 approved-only; min-0.05 rejected-only"
  - "export_jsonl edit action uses correction.edited_response (already PII-redacted in store); falls back to cai_critique.revised_output then trace.response"
  - "CLI __main__.py rewritten to match eval/__main__.py pattern exactly: subparsers variable, _resolve_db_path, asyncio.run() for async commands"
  - "export subcommand --output defaults to corrections.jsonl (not required) so CLI never errors on missing arg"

patterns-established:
  - "Calibration: group corrections by triggering rail, apply MIN_CORRECTIONS guard, return structured suggestion dicts"
  - "JSONL export: for each correction fetch trace, apply action-based response selection, write one JSON line"
  - "CLI: _resolve_db_path helper reads HARNESS_DATA_DIR env var with harness/data fallback"

requirements-completed: [HITL-03]

# Metrics
duration: 5min
completed: 2026-03-23
---

# Phase 10 Plan 02: HITL Calibration and Export Summary

**Per-rail threshold calibration engine and OpenAI JSONL fine-tuning exporter with TDD tests and CLI subcommands**

## Performance

- **Duration:** 5 min
- **Started:** 2026-03-23T07:11:57Z
- **Completed:** 2026-03-23T07:16:39Z
- **Tasks:** 2 (Task 1 TDD: RED + GREEN, Task 2: CLI entry point)
- **Files modified:** 4

## Accomplishments

- `compute_calibration()` groups corrections by triggering rail, applies MIN_CORRECTIONS=5 guard, and computes threshold suggestions using midpoint/P95/below-min strategies
- `export_jsonl()` writes OpenAI-format JSONL with messages array and label field; handles edit/cai_critique/fallback response selection
- CLI `__main__.py` rewritten to match `eval/__main__.py` pattern with `subparsers`, `_resolve_db_path`, and graceful Gradio import failure message
- 10 new tests added (7 calibrate/export + 3 CLI); all 29 HITL tests and 198 total suite tests pass

## Task Commits

Each task was committed atomically:

1. **Task 1 RED: Failing tests for calibrate and export** - `8afe334` (test)
2. **Task 1 GREEN: compute_calibration and export_jsonl** - `b933d1a` (feat)
3. **Task 2: CLI entry point** - `f9cb04e` (feat)

_Note: TDD task has RED + GREEN commits_

## Files Created/Modified

- `harness/hitl/calibrate.py` — compute_calibration() with MIN_CORRECTIONS=5 guard and three suggestion strategies
- `harness/hitl/export.py` — export_jsonl() writing OpenAI-format JSONL with action-based response selection
- `harness/hitl/__main__.py` — CLI entry point rewritten to match eval/__main__.py pattern exactly
- `harness/tests/test_hitl.py` — 10 new tests for calibrate, export, and CLI subcommands

## Decisions Made

- `compute_calibration` uses midpoint strategy when both approved and rejected scores exist; P95 of approved-only; min-0.05 for rejected-only — mirrors plan specification exactly
- `export_jsonl` edit action uses `correction.edited_response` (already PII-redacted by TraceStore); non-edit falls back to cai_critique.revised_output then trace.response
- CLI `__main__.py` rewritten from scratch (previous version had different structure and a bug: passed `since` kwarg to `export_jsonl` which doesn't accept it)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed broken export_jsonl call in pre-existing __main__.py**
- **Found during:** Task 2 (CLI entry point)
- **Issue:** Pre-existing `__main__.py` called `export_jsonl(store, output_path=..., since=args.since)` but `export_jsonl` only accepts `output_path` — would raise `TypeError` at runtime
- **Fix:** Rewrote `__main__.py` to match plan specification exactly; removed the spurious `since` argument
- **Files modified:** harness/hitl/__main__.py
- **Verification:** All CLI tests pass; `python -m harness.hitl --help` shows correct subcommands
- **Committed in:** f9cb04e (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 - Bug)
**Impact on plan:** Fix was necessary for CLI correctness. No scope creep.

## Issues Encountered

- Pre-existing `__main__.py` from a prior execution existed and had structural mismatches (no `subparsers` variable, no `_resolve_db_path`, wrong install string, broken `since` argument to `export_jsonl`). Replaced with plan-spec version.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- HITL-03 satisfied: reviewer corrections now feed back into threshold calibration and fine-tuning data
- All four HITL requirements (HITL-01 through HITL-04) are now implemented
- Phase 10 complete

---
*Phase: 10-hitl-dashboard*
*Completed: 2026-03-23*
