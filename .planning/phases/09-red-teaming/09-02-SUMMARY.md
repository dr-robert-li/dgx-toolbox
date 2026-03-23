---
phase: 09-red-teaming
plan: 02
subsystem: api
tags: [redteam, garak, asyncio, fastapi, adversarial, pytest, tdd]

# Dependency graph
requires:
  - phase: 09-01
    provides: balance.py check_balance, TraceStore job CRUD + query_near_misses, redteam.yaml config
  - phase: 07-constitutional-ai
    provides: CritiqueEngine._call_judge pattern, http_client POST /v1/chat/completions
  - phase: 05-gateway-and-trace-foundation
    provides: TraceStore, verify_api_key, main.py lifespan pattern, app.state

provides:
  - garak subprocess wrapper (asyncio.create_subprocess_exec, JSONL report parsing)
  - deepteam adversarial generation engine (near-miss query + judge model variants)
  - FastAPI admin router at /admin/redteam with submit/status/list + 409 conflict gate
  - CLI promote command with balance enforcement (python -m harness.redteam promote)
  - main.py wired with redteam_lock, redteam_router, redteam_active_task

affects:
  - 10-hitl-dashboard

# Tech tracking
tech-stack:
  added: [garak>=0.14 (optional dependency)]
  patterns:
    - asyncio.Lock for single-job concurrency gate (lock.locked() public API check)
    - asyncio.create_task stores reference in app.state to prevent GC
    - PENDING_DIR patched via patch.object in tests for isolation
    - TDD with AsyncMock/MagicMock for subprocess and HTTP client mocking

key-files:
  created:
    - harness/redteam/garak_runner.py
    - harness/redteam/engine.py
    - harness/redteam/router.py
    - harness/redteam/__main__.py
    - harness/tests/test_redteam.py
  modified:
    - harness/main.py
    - harness/pyproject.toml

key-decisions:
  - "asyncio.Lock (not Semaphore) for single-job gate — lock.locked() is public API; Semaphore._value is private"
  - "asyncio.create_task result stored in app.state.redteam_active_task to prevent garbage collection"
  - "garak runner uses asyncio.create_subprocess_exec not subprocess.run — avoids blocking event loop"
  - "deepteam engine wraps all variant generation exceptions with empty-list fallback — fail-open for adversarial generation"
  - "near_miss_min_count guard skips deepteam job when insufficient near-miss data — avoids noisy low-sample generation"

patterns-established:
  - "Single-job lock pattern: asyncio.Lock + lock.locked() check before create_task dispatch"
  - "Background job task reference: app.state.redteam_active_task = asyncio.create_task(...)"
  - "Fail-open adversarial generation: except (json.JSONDecodeError, KeyError, IndexError, Exception): return []"

requirements-completed: [RDTM-01, RDTM-02, RDTM-03, RDTM-04]

# Metrics
duration: 7min
completed: 2026-03-23
---

# Phase 9 Plan 02: Red Team Active Components Summary

**garak async subprocess wrapper, judge-based adversarial generation from near-miss traces, FastAPI admin router with 409 conflict gate, and CLI promote with balance enforcement**

## Performance

- **Duration:** 7 min
- **Started:** 2026-03-23T05:55:00Z
- **Completed:** 2026-03-23T06:02:17Z
- **Tasks:** 2
- **Files modified:** 7

## Accomplishments

- garak_runner.py wraps garak as async subprocess with OPENAICOMPATIBLE_API_KEY injection and JSONL report parsing
- engine.py queries near-miss traces from TraceStore and generates adversarial variants via judge model, writing to pending JSONL
- router.py provides 3 admin endpoints (POST submit, GET status, GET list) with asyncio.Lock-based 409 conflict gate and asyncio.create_task dispatch
- __main__.py delivers CLI `promote` command that runs balance check before moving pending dataset to active directory
- main.py wired with redteam_lock initialization and redteam_router registration in lifespan
- 16 TDD tests pass (8 unit + 8 router/CLI); full 169-test suite all green

## Task Commits

Each task was committed atomically:

1. **Task 1: garak runner, deepteam engine, and unit tests** - `a39bf90` (feat)
2. **Task 2: Router with async dispatch, CLI promote, main.py wiring, pyproject.toml** - `2d7005a` (feat)

**Plan metadata:** (docs commit — added after SUMMARY)

_Note: Both tasks used TDD pattern (RED → GREEN)_

## Files Created/Modified

- `harness/redteam/garak_runner.py` - asyncio subprocess wrapper with parse_garak_report for JSONL probe scores
- `harness/redteam/engine.py` - generate_adversarial_variants + run_deepteam_job with near-miss query and pending JSONL write
- `harness/redteam/router.py` - FastAPI admin router with 3 endpoints, asyncio.Lock gate, asyncio.create_task dispatch
- `harness/redteam/__main__.py` - CLI promote (balance check + shutil.move) and list commands
- `harness/main.py` - added redteam_lock/redteam_current_job_id/redteam_active_task in lifespan + redteam_router registration
- `harness/pyproject.toml` - added redteam optional dependency group with garak>=0.14
- `harness/tests/test_redteam.py` - 16 tests covering garak runner, deepteam engine, router endpoints, CLI promote

## Decisions Made

- Used `asyncio.Lock` not `asyncio.Semaphore` — `lock.locked()` is the public API; `Semaphore._value` is private and fragile
- `asyncio.create_task` result stored in `app.state.redteam_active_task` — prevents garbage collection of background task
- `garak_runner.py` uses `asyncio.create_subprocess_exec` not `subprocess.run` — keeps event loop unblocked during long scans
- Adversarial generation uses fail-open pattern — `except Exception: return []` ensures single variant failure never crashes job
- `near_miss_min_count` guard in `run_deepteam_job` skips generation when below 5 near-misses — avoids noisy low-sample output

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None - both TDD cycles (RED → GREEN) succeeded on first implementation pass.

## Self-Check: PASSED

## User Setup Required

None - no external service configuration required. The `garak` optional dependency requires separate `pip install dgx-harness[redteam]` when running garak scans.

## Next Phase Readiness

- All 4 RDTM requirements (RDTM-01 through RDTM-04) delivered
- Red teaming phase complete — Phase 10 HITL Dashboard can now use job data from redteam_jobs table
- garak scan data available in SQLite via `trace_store.get_job` / `trace_store.list_jobs`
- Pending adversarial datasets in `harness/eval/datasets/pending/` ready for CLI promotion

---
*Phase: 09-red-teaming*
*Completed: 2026-03-23*
