---
phase: 10-hitl-dashboard
plan: 01
subsystem: api
tags: [fastapi, sqlite, aiosqlite, pii-redaction, hitl, corrections, priority-queue]

requires:
  - phase: 09-red-teaming
    provides: TraceStore with near-miss traces and guardrail_decisions data
  - phase: 08-eval-harness-and-ci-gate
    provides: eval_runs and corrections schema patterns
  - phase: 05-gateway-and-trace-foundation
    provides: TraceStore base class, trace schema, auth patterns

provides:
  - corrections table DDL in schema.sql (idempotent CREATE TABLE IF NOT EXISTS)
  - TraceStore.write_correction() with PII redaction via redact_text()
  - TraceStore.query_corrections() with optional request_id filter
  - TraceStore.query_hitl_queue() with priority sort, rail/tenant/time/hide_reviewed filters
  - compute_priority() and _extract_triggering_rail() module-level helpers in store.py
  - GET /admin/hitl/queue endpoint with triple filter support
  - POST /admin/hitl/correct endpoint with Pydantic action enum validation
  - harness/hitl/router.py with hitl_router (prefix /admin/hitl)
  - hitl optional dependency group in pyproject.toml

affects: [10-02-hitl-gradio-ui, 10-03-hitl-cli-tools]

tech-stack:
  added: []
  patterns:
    - Priority score = 1.0 - min(threshold - score) for all rail results with score > 0
    - LEFT JOIN corrections on traces to detect reviewed items in single SQL query
    - Python post-processing for rail filter and hide_reviewed after SQL fetch
    - PII redaction via redact_text() before SQLite INSERT (corrections.edited_response)
    - CorrectionRequest Pydantic model with Literal action enum for 422 validation
    - _resolve_since() reuse from harness.proxy.admin for consistent shorthand parsing

key-files:
  created:
    - harness/hitl/__init__.py
    - harness/hitl/router.py
    - harness/tests/test_hitl.py
  modified:
    - harness/traces/schema.sql
    - harness/traces/store.py
    - harness/main.py
    - harness/pyproject.toml

key-decisions:
  - "compute_priority uses 1.0 - min(distances) formula: closest-to-threshold = highest priority"
  - "_extract_triggering_rail returns rail from all_results entry with minimum distance from threshold"
  - "SQL LEFT JOIN corrections pattern: reviewed status detected in single query, no N+1"
  - "hide_reviewed and rail_filter applied in Python post-processing after SQL fetch (simpler than JSON SQL)"
  - "reviewed items sorted after unreviewed via tuple key (correction_action is not None, -priority)"
  - "CorrectionRequest uses Literal['approve','reject','edit'] for FastAPI 422 on invalid action"
  - "Harness starts without gradio installed: hitl router has no gradio import, endpoints work headlessly"

patterns-established:
  - "HITL queue: LEFT JOIN + Python sort pattern for priority + reviewed-last ordering"
  - "Correction PII redaction: redact_text() called in write_correction() before INSERT"

requirements-completed: [HITL-01, HITL-02, HITL-04]

duration: 5min
completed: 2026-03-23
---

# Phase 10 Plan 01: HITL API Foundation Summary

**Priority-sorted HITL queue (GET /admin/hitl/queue) and correction submission (POST /admin/hitl/correct) with SQLite corrections table, PII-redacted edited responses, and triple filter support (rail/tenant/time)**

## Performance

- **Duration:** ~5 min
- **Started:** 2026-03-23T07:05:18Z
- **Completed:** 2026-03-23T07:09:31Z
- **Tasks:** 2
- **Files modified:** 7

## Accomplishments

- Corrections table DDL appended to schema.sql with idempotent CREATE TABLE IF NOT EXISTS pattern
- TraceStore extended with write_correction (PII-redacted), query_corrections, query_hitl_queue (priority-sorted)
- FastAPI HITL router with auth-gated GET /queue and POST /correct endpoints registered in main.py
- 19 tests pass covering schema idempotency, PII redaction, priority sort, all three filters, auth, headless mode, and response shape

## Task Commits

1. **Task 1: corrections schema, TraceStore extensions, and tests** - `ed384cc` (feat)
2. **Task 2: HITL FastAPI router, app wiring, pyproject.toml update** - `3a808d3` (feat)

## Files Created/Modified

- `harness/traces/schema.sql` - corrections table DDL with CHECK constraint on action
- `harness/traces/store.py` - compute_priority(), _extract_triggering_rail(), write_correction(), query_corrections(), query_hitl_queue()
- `harness/hitl/__init__.py` - package marker (empty)
- `harness/hitl/router.py` - hitl_router with GET /queue and POST /correct, CorrectionRequest model
- `harness/main.py` - hitl_router registered after redteam_router
- `harness/pyproject.toml` - hitl = ["gradio>=6.0,<7.0"] optional dependency group
- `harness/tests/test_hitl.py` - 19 tests covering schema, store, and endpoint behaviors

## Decisions Made

- compute_priority formula: `1.0 - min(threshold - score)` across all rail results with score > 0 — closest-to-threshold gets priority closest to 1.0
- Reviewed items sorted last using tuple sort key `(correction_action is not None, -priority)` — stable, efficient
- SQL uses LEFT JOIN corrections to fetch reviewed status in one query, Python post-processes for rail_filter and hide_reviewed (avoids complex JSON SQL parsing in SQLite)
- CorrectionRequest uses `Literal["approve", "reject", "edit"]` — FastAPI automatically returns 422 for invalid action before it reaches the handler
- hitl_router has no import of gradio — headless API mode works without installing gradio optional deps

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- GET /admin/hitl/queue and POST /admin/hitl/correct are ready for Gradio UI wrapper (Plan 02)
- query_hitl_queue() returns priority, triggering_rail, correction_action, cai_critique fields needed by UI
- All endpoints require auth — CLI tools (Plan 03) will use the same auth pattern

## Self-Check: PASSED

All created files exist on disk. Both task commits verified in git log (ed384cc, 3a808d3).

---
*Phase: 10-hitl-dashboard*
*Completed: 2026-03-23*
