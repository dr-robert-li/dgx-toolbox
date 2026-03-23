---
phase: 09-red-teaming
plan: "01"
subsystem: database
tags: [sqlite, aiosqlite, red-teaming, garak, deepteam, balance-check, near-miss]

requires:
  - phase: 08-eval-harness-and-ci-gate
    provides: "TraceStore with eval_runs table; traces table schema pattern"

provides:
  - "redteam_jobs table DDL in schema.sql with type and status CHECK constraints"
  - "TraceStore.create_job, update_job_status, get_job, list_jobs, query_near_misses"
  - "harness/redteam/balance.py check_balance() enforcing max_category_ratio"
  - "harness/config/redteam.yaml with max_category_ratio and near_miss_window_days"
  - "3 garak profile YAMLs (quick/standard/thorough) with OpenAICompatible.uri nesting"
  - "harness/eval/datasets/pending/ staging directory"

affects:
  - 09-red-teaming/09-02 (garak runner, deepteam engine, router all depend on this data layer)
  - 10-hitl-dashboard (reads redteam_jobs via TraceStore)

tech-stack:
  added: []
  patterns:
    - "redteam_jobs CRUD follows same aiosqlite pattern as eval_runs (write_eval_run / query_eval_runs)"
    - "query_near_misses uses SQL for pre-filtering (refusal_event=0, guardrail_decisions IS NOT NULL) then Python post-filter for score > 0"
    - "garak profile YAML requires plugins.generators.openai.OpenAICompatible.uri nesting (not top-level)"

key-files:
  created:
    - harness/redteam/__init__.py
    - harness/redteam/balance.py
    - harness/config/redteam.yaml
    - harness/config/redteam_quick.yaml
    - harness/config/redteam_standard.yaml
    - harness/config/redteam_thorough.yaml
    - harness/eval/datasets/pending/.gitkeep
    - harness/tests/test_redteam_data.py
  modified:
    - harness/traces/schema.sql
    - harness/traces/store.py

key-decisions:
  - "query_near_misses uses SQL pre-filter (refusal_event=0) then Python score>0 post-filter — avoids complex SQL JSON parsing while keeping DB reads bounded"
  - "garak YAML profiles use plugins.generators.openai.OpenAICompatible.uri nesting — garak silently ignores wrong nesting (inherited from Phase 9 research)"
  - "check_balance counts active datasets AND pending in combined total — ensures balance is evaluated on final merged state not just delta"

patterns-established:
  - "RedTeam job lifecycle: pending -> running -> complete|failed via update_job_status"
  - "Balance check returns (ok: bool, violations: dict[str, float]) — empty dict means no violations"

requirements-completed: [RDTM-03, RDTM-04]

duration: 15min
completed: "2026-03-23"
---

# Phase 9 Plan 01: Red Team Data Layer Summary

**SQLite redteam_jobs table with TraceStore CRUD, near-miss query filtering on guardrail scores, check_balance() ratio enforcement, and 3 garak profile YAMLs with correct OpenAICompatible.uri nesting**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-03-23T05:39:00Z
- **Completed:** 2026-03-23T05:54:05Z
- **Tasks:** 2
- **Files modified:** 10

## Accomplishments

- Extended schema.sql with redteam_jobs table (CHECK constraints on type and status)
- Added 5 TraceStore methods: create_job, update_job_status, get_job, list_jobs, query_near_misses
- Created check_balance() in harness/redteam/balance.py enforcing max_category_ratio=0.40
- Created redteam.yaml config and 3 garak profile YAMLs with correct nesting
- 17 tests passing; all 153 existing tests continue to pass

## Task Commits

Each task was committed atomically:

1. **RED tests** - `8ed38b7` (test: add failing tests for redteam data layer)
2. **Task 1: Schema extension, TraceStore job CRUD, near-miss query** - `517006c` (feat)
3. **Task 2: Balance check, configs, garak profiles, pending dir** - `9e6fce9` (feat)

_Note: TDD tasks have separate test (RED) and implementation (GREEN) commits_

## Files Created/Modified

- `harness/traces/schema.sql` - Appended redteam_jobs DDL with type/status CHECK constraints and indexes
- `harness/traces/store.py` - Added create_job, update_job_status, get_job, list_jobs, query_near_misses
- `harness/redteam/__init__.py` - Package scaffold (empty init)
- `harness/redteam/balance.py` - check_balance() function with max_category_ratio enforcement
- `harness/config/redteam.yaml` - Main red team config (max_category_ratio, near_miss_window_days, etc.)
- `harness/config/redteam_quick.yaml` - Quick garak scan profile (~2-5 min)
- `harness/config/redteam_standard.yaml` - Standard garak scan profile (~10-20 min)
- `harness/config/redteam_thorough.yaml` - Thorough garak scan profile (~30-60 min)
- `harness/eval/datasets/pending/.gitkeep` - Staging directory for adversarial datasets
- `harness/tests/test_redteam_data.py` - 17 tests covering all new methods and balance logic

## Decisions Made

- query_near_misses uses SQL pre-filter (refusal_event=0, guardrail_decisions IS NOT NULL) then Python post-filter for score > 0. Avoids complex SQL JSON parsing while keeping DB reads bounded by the SQL LIMIT.
- check_balance counts active AND pending in combined total — evaluates balance on final merged state, not just the delta batch.
- garak YAML profiles use `plugins.generators.openai.OpenAICompatible.uri` nesting — garak silently ignores wrong nesting (critical pattern from Phase 9 research).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed test_balance_check_combines_active_and_pending assertion**
- **Found during:** Task 2 (balance check tests GREEN run)
- **Issue:** Test comment said "10 injection out of 20 total" but actual combined total was 25 (5 active + 20 pending). With 20 pending entries (5 injection + 15 other), `other` at 60% was the violation, not `injection` at 40%.
- **Fix:** Changed test to use only injection entries in pending (no `other` category) so injection clearly exceeds 0.40 at 15/15=100%.
- **Files modified:** harness/tests/test_redteam_data.py
- **Verification:** All 5 balance tests pass
- **Committed in:** 9e6fce9 (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 — incorrect test assertion)
**Impact on plan:** Test logic corrected; implementation behavior unchanged. No scope creep.

## Issues Encountered

None beyond the test assertion fix above.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Data layer complete; Plan 09-02 can proceed with garak runner, deepteam engine, and router
- redteam_jobs table available for job tracking
- query_near_misses available for near-miss driven prompt variant generation
- garak profile YAMLs ready for use with the gateway at http://localhost:8080/v1/

---
*Phase: 09-red-teaming*
*Completed: 2026-03-23*

## Self-Check: PASSED

All created files verified present. All commits (ee3d1f6, 517006c, 9e6fce9) verified in git log.
