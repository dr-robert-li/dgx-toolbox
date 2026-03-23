---
phase: 10-hitl-dashboard
plan: 03
subsystem: ui
tags: [gradio, httpx, hitl, dashboard, diff-view]

# Dependency graph
requires:
  - phase: 10-hitl-dashboard/10-01
    provides: HITL API endpoints (GET /admin/hitl/queue, POST /admin/hitl/correct)
  - phase: 10-hitl-dashboard/10-02
    provides: CLI entry point (__main__.py) with ui/calibrate/export subcommands
provides:
  - Standalone Gradio HITL review dashboard (harness/hitl/ui.py)
  - Two-panel master-detail layout with priority-sorted queue and diff view
  - Approve/Reject/Edit correction workflow via httpx calls to harness API
  - build_ui(api_url, api_key) -> gr.Blocks factory function
affects: []

# Tech tracking
tech-stack:
  added: [gradio, httpx (sync client for Gradio callbacks)]
  patterns: [Gradio Blocks layout with left/right panels, sync httpx.Client in Gradio callbacks, difflib.unified_diff for side-by-side diff, graceful API error handling in UI]

key-files:
  created:
    - harness/hitl/ui.py
    - harness/hitl/__main__.py
  modified: []

key-decisions:
  - "Gradio UI defaults to port 8501 (not 8080) — harness runs on 8080, LiteLLM on 4000; 8501 avoids all conflicts"
  - "Port is fully configurable via --port CLI arg on python -m harness.hitl ui subcommand"
  - "Sync httpx.Client used inside Gradio callbacks — Gradio runs its own event loop separately from uvicorn"
  - "cai_critique=None handled with single-column original output + 'Blocked before revision' label in revised column"

patterns-established:
  - "Pattern 1: Gradio callbacks use sync httpx.Client (not async) — Gradio event system is synchronous"
  - "Pattern 2: API errors displayed in status Textbox, not raised as exceptions — UI never crashes on backend unavailability"
  - "Pattern 3: build_ui() returns gr.Blocks object — caller (CLI) controls .launch() with port/auth args"

requirements-completed: [HITL-01, HITL-02]

# Metrics
duration: 20min
completed: 2026-03-23
---

# Phase 10 Plan 03: HITL Dashboard Gradio UI Summary

**Gradio two-panel HITL review dashboard with priority-sorted queue, side-by-side unified diff, and approve/reject/edit correction workflow connecting to harness API via sync httpx**

## Performance

- **Duration:** ~20 min
- **Started:** 2026-03-23T17:00:00+10:00 (estimated)
- **Completed:** 2026-03-23T17:14:42+10:00
- **Tasks:** 2 (1 auto + 1 human-verify checkpoint)
- **Files modified:** 2

## Accomplishments

- Gradio two-panel master-detail layout: left panel with filter dropdowns + queue dataframe, right panel with diff view + correction buttons
- Priority-sorted queue table showing timestamp, tenant, rail, priority score, action taken, status badge, and truncated prompt
- Side-by-side diff view: original vs revised output using difflib.unified_diff; cai_critique=None handled with "Blocked before revision" label
- Approve/Reject/Edit correction workflow via POST /admin/hitl/correct; Edit action toggles editable response textbox
- All API errors displayed gracefully in status textbox — UI never crashes when harness is unreachable

## Task Commits

Each task was committed atomically:

1. **Task 1: Gradio two-panel review UI with diff view and correction actions** - `6d3e596` (feat)
2. **Task 2: Visual verification of HITL dashboard** - human-verify checkpoint (approved by user)

**Plan metadata:** (docs commit — this summary)

## Files Created/Modified

- `harness/hitl/ui.py` - Standalone Gradio HITL dashboard (427 lines); exports build_ui(api_url, api_key)
- `harness/hitl/__main__.py` - CLI entry point with ui/calibrate/export subcommands (116 lines)

## Decisions Made

- Gradio dashboard defaults to port 8501 (not 8080). Port 8080 is used by the harness, port 4000 by LiteLLM. The --port CLI arg on `python -m harness.hitl ui` allows overriding to any port. During verification, user noted port 8080 was already in use — this was expected and not a bug since the harness intentionally runs there.
- Sync httpx.Client used inside Gradio callbacks (Gradio's event loop is synchronous; using async client would require run_coroutine_threadsafe workarounds).
- build_ui() returns gr.Blocks without calling .launch() — separation of construction from serving lets the CLI control port, auth, and server config.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- Port conflict observation during human verification: port 8080 was already in use by the harness API. The Gradio UI runs on port 8501 by default (separate port), so no actual conflict exists. The --port flag allows further customization. No code changes needed.

## User Setup Required

None - no external service configuration required beyond installing Gradio (`pip install gradio`) in the harness virtual environment.

## Next Phase Readiness

- Phase 10 HITL Dashboard is complete: API endpoints (Plan 01), calibration/export CLI (Plan 02), Gradio review UI (Plan 03)
- All HITL-01 and HITL-02 requirements fulfilled
- v1.1 Safety Harness is fully complete across all 10 phases
- Ready for Phase 5 planning (`/gsd:plan-phase 5`) to start a fresh v1.1 implementation cycle

---
*Phase: 10-hitl-dashboard*
*Completed: 2026-03-23*
