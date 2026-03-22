---
phase: 07-constitutional-ai-critique
plan: "03"
subsystem: critique
tags: [constitutional-ai, tuning-analysis, admin-api, cli, sqlite]
dependency_graph:
  requires:
    - 07-01  # constitution.py, ConstitutionConfig, load_constitution
    - 05-xx  # TraceStore.query_by_timerange, SQLite schema with cai_critique
  provides:
    - analyze_traces()  # harness/critique/analyzer.py
    - POST /admin/suggest-tuning  # harness/proxy/admin.py
    - python -m harness.critique analyze  # harness/critique/__main__.py
  affects:
    - harness/critique/__init__.py  # new analyze_traces export
    - harness/main.py  # admin_router registered
tech_stack:
  added: []
  patterns:
    - Counter-based aggregate extraction from SQLite critique records
    - Judge model call via http_client.post with structured system prompt
    - MIN_SAMPLE_SIZE guard before expensive judge call
    - _resolve_since() shorthand-to-ISO8601 helper shared between admin and CLI
    - TDD: failing tests committed before implementation (RED→GREEN)
key_files:
  created:
    - harness/critique/analyzer.py
    - harness/critique/__main__.py
    - harness/proxy/admin.py
    - harness/tests/test_analyzer.py
  modified:
    - harness/critique/__init__.py
    - harness/main.py
decisions:
  - "MIN_SAMPLE_SIZE=10: fewer than 10 cai_critique records returns structured empty result without calling judge — avoids noisy suggestions from small samples"
  - "Judge JSON parse failure returns structured error dict (not an exception) — admin endpoint and CLI never crash on bad model output"
  - "admin_router uses lazy import of analyze_traces inside handler — avoids circular import at module load"
  - "_resolve_since() shared between admin.py and __main__.py — consistent shorthand handling"
metrics:
  duration_seconds: 392
  completed_date: "2026-03-22"
  tasks_completed: 2
  files_created: 4
  files_modified: 2
  tests_added: 6
  tests_total: 109
---

# Phase 07 Plan 03: Tuning Analysis System Summary

**One-liner:** SQLite critique aggregation + judge-model pattern analysis producing ranked threshold/principle suggestions as markdown report + yaml_diffs list, with admin API and CLI entry points.

## Objective

Build the feedback loop closer between production CAI behavior and configuration tuning (CSTL-05). The `analyze_traces()` function reads historical cai_critique records, aggregates patterns, calls a judge model, and returns ranked tuning suggestions in both human-readable and machine-readable formats.

## Tasks Completed

### Task 1: analyze_traces() function and tests (TDD)

**RED phase (f484a60):** Six failing tests committed covering:
- Normal analysis with 15 critique records
- Empty trace history (no judge call)
- Below-minimum sample (no judge call)
- yaml_diffs structure validation
- Aggregate pattern passing to judge prompt
- Graceful JSON parse failure

**GREEN phase (4faea41):** Implementation in `harness/critique/analyzer.py`:
- `MIN_SAMPLE_SIZE = 10` guard returns structured empty result with count
- Aggregates: per-rail trigger frequency, per-principle violation frequency, outcome distribution, avg confidence, threshold stats (mean original/revision scores)
- Resolves judge model: `judge_model` param → `constitution.judge_model` → `"unknown"`
- Calls judge via `/v1/chat/completions` with structured system prompt requiring JSON output
- Transforms judge suggestions into ranked markdown report and yaml_diffs list
- Graceful failure: JSON parse error returns `{"report": "Analysis failed...", "yaml_diffs": [], ...}`
- Updated `harness/critique/__init__.py` to export `analyze_traces`

All 6 new tests pass. 72 existing tests still pass.

### Task 2: Admin endpoint, CLI entry point, lifespan wiring (440c69a)

**harness/proxy/admin.py:**
- `admin_router = APIRouter(prefix="/admin", tags=["admin"])`
- `POST /admin/suggest-tuning`: auth via `verify_api_key`, `since` query param (default "24h"), reads `app.state.trace_store`, `http_client`, and `critique_engine.constitution`; returns 503 if CAI not configured
- `_resolve_since()`: converts `24h`/`7d` shorthand to ISO8601 timestamps

**harness/critique/__main__.py:**
- `python -m harness.critique analyze --since 24h` entry point
- `argparse` with `analyze` subcommand; supports `--since`, `--min-samples`, `--db`, `--config-dir`
- Loads constitution + TraceStore, calls `analyze_traces()`, prints markdown report + JSON yaml_diffs

**harness/main.py:**
- `from harness.proxy.admin import admin_router` + `app.include_router(admin_router)`

Full suite: 109 passed, 1 skipped, no regressions.

## Deviations from Plan

None — plan executed exactly as written.

The `harness/main.py` already had `critique_engine` initialization from Plan 02's auto-commit. The `admin_router` include was the only addition needed, which was applied correctly.

## Acceptance Criteria Verification

- harness/critique/analyzer.py contains "async def analyze_traces(" — PASS
- harness/critique/analyzer.py contains "MIN_SAMPLE_SIZE = 10" — PASS
- harness/critique/analyzer.py contains "Insufficient data" — PASS
- harness/critique/analyzer.py contains "Analysis failed" — PASS
- harness/critique/analyzer.py contains "## Tuning Suggestions" — PASS
- harness/critique/analyzer.py contains "yaml_diffs" — PASS
- harness/critique/__init__.py contains "analyze_traces" — PASS
- harness/tests/test_analyzer.py contains all 6 required test function names — PASS
- harness/proxy/admin.py contains admin_router, endpoint, analyze_traces import — PASS
- harness/critique/__main__.py contains main(), analyze_parser, --since, asyncio.run — PASS
- harness/main.py contains admin_router import and include_router — PASS
- All tests pass: 109 passed — PASS

## Self-Check: PASSED

Files verified:
- harness/critique/analyzer.py — exists, contains MIN_SAMPLE_SIZE=10
- harness/critique/__main__.py — exists, contains def main()
- harness/proxy/admin.py — exists, contains admin_router
- harness/tests/test_analyzer.py — exists, 6 test functions
- Commits: f484a60 (RED), 4faea41 (GREEN), 440c69a (Task 2) — all present in git log
