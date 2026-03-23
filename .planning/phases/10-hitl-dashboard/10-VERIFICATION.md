---
phase: 10-hitl-dashboard
verified: 2026-03-23T07:45:00Z
status: passed
score: 12/12 must-haves verified
human_verification:
  - test: "Launch `python -m harness.hitl ui --port 8501 --api-url http://localhost:8080 --api-key sk-test` and open http://localhost:8501"
    expected: "Two-panel dashboard loads; left panel shows filter dropdowns and queue table; right panel shows diff view area with Approve/Reject/Edit buttons"
    why_human: "Gradio UI visual layout and interactive behaviour cannot be verified from code inspection alone"
  - test: "Load queue data in UI, select a flagged trace with cai_critique, verify side-by-side diff appears"
    expected: "Original Output and Revised Output textboxes populated from cai_critique.original_output / revised_output; diff textbox shows unified diff lines"
    why_human: "Runtime Gradio event wiring and data rendering requires live interaction"
  - test: "Select a flagged trace where cai_critique is None"
    expected: "Original Output shows the trace response; Revised Output shows 'Blocked before revision - no revised output available'"
    why_human: "Requires a real trace record with cai_critique=null in the database"
  - test: "Submit Approve, Reject, and Edit actions from the UI"
    expected: "Status textbox shows 'OK — <action> submitted for <request_id>'; refreshing queue shows updated status badge for the reviewed item"
    why_human: "Full round-trip correction submission and queue refresh requires live harness + Gradio interaction"
---

# Phase 10: HITL Dashboard Verification Report

**Phase Goal:** Operators can review flagged requests through a Gradio UI sorted by review priority, apply corrections that feed back into threshold calibration and fine-tuning data, and access the same workflow via API when no UI is available.
**Verified:** 2026-03-23T07:45:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | GET /admin/hitl/queue returns priority-sorted flagged traces with closest-to-threshold items first | VERIFIED | `query_hitl_queue` in store.py lines 393-481 implements SQL LEFT JOIN + Python sort on `(correction_action is not None, -priority)`; 29 tests pass |
| 2 | POST /admin/hitl/correct writes a correction record to SQLite with PII-redacted edited_response | VERIFIED | `write_correction` in store.py lines 335-370; imports `redact` from `harness.pii.redactor` and applies it to edited_response before INSERT |
| 3 | Queue items annotated with reviewed status drop to bottom | VERIFIED | Python sort key `(correction_action is not None, -priority)` in store.py line 477-479 |
| 4 | Triple filter (rail type, tenant, time range) narrows queue results | VERIFIED | SQL WHERE clause filters tenant and time; Python post-processes rail_filter; test_queue_rail_filter, test_queue_tenant_filter, test_queue_time_filter all pass |
| 5 | Harness starts and queue endpoint works without Gradio installed | VERIFIED | `harness/hitl/router.py` has no gradio import; `__main__.py` guards `from harness.hitl.ui import build_ui` behind try/except ImportError with helpful install message |
| 6 | corrections table DDL is idempotent | VERIFIED | `CREATE TABLE IF NOT EXISTS corrections` in schema.sql line 47; `test_schema_idempotent` passes |
| 7 | python -m harness.hitl calibrate reads corrections and outputs per-rail threshold suggestions | VERIFIED | `compute_calibration()` in calibrate.py fully implemented with midpoint/P95/below-min strategies; CLI wired in __main__.py |
| 8 | python -m harness.hitl export --format jsonl writes OpenAI-format JSONL | VERIFIED | `export_jsonl()` in export.py writes `{"messages": [...], "label": action}` records; tested by test_export_jsonl_format |
| 9 | Calibration respects MIN_CORRECTIONS=5 guard | VERIFIED | `MIN_CORRECTIONS = 5` constant in calibrate.py line 6; guard at line 94; test_calibrate_min_corrections passes |
| 10 | Gradio dashboard has two-panel master-detail layout | VERIFIED (code) / ? HUMAN NEEDED (visual) | ui.py line 291-427: `gr.Row` with `gr.Column(scale=1)` (filters+queue) and `gr.Column(scale=2)` (detail+diff+buttons); 427 lines total |
| 11 | Side-by-side diff view populated from cai_critique | VERIFIED (code) / ? HUMAN NEEDED (runtime) | select_item() in ui.py lines 214-226 parses cai_critique and runs difflib.unified_diff; cai_critique=None handled at lines 228-233 with "Blocked before revision" |
| 12 | Approve/Reject/Edit actions submit corrections via POST /admin/hitl/correct | VERIFIED (code) / ? HUMAN NEEDED (runtime) | submit_correction() in ui.py lines 245-266 POSTs to `/admin/hitl/correct`; buttons wired at lines 392-425 |

**Score:** 12/12 truths verified (4 additionally require human confirmation at runtime)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `harness/traces/schema.sql` | corrections table DDL | VERIFIED | `CREATE TABLE IF NOT EXISTS corrections` at line 47 with CHECK constraint on action |
| `harness/traces/store.py` | write_correction, query_hitl_queue, query_corrections methods | VERIFIED | All three methods present (lines 335, 372, 393); compute_priority and _extract_triggering_rail also present |
| `harness/hitl/router.py` | FastAPI HITL admin endpoints | VERIFIED | hitl_router with prefix="/admin/hitl"; GET /queue and POST /correct; CorrectionRequest Pydantic model |
| `harness/hitl/__init__.py` | Package marker | VERIFIED | File exists (0 bytes) |
| `harness/main.py` | HITL router registration | VERIFIED | `app.include_router(hitl_router)` at line 100 |
| `harness/tests/test_hitl.py` | 29 unit tests | VERIFIED | All 29 tests pass |
| `harness/hitl/calibrate.py` | compute_calibration() with MIN_CORRECTIONS guard | VERIFIED | 133 lines; full implementation with three threshold strategies |
| `harness/hitl/export.py` | export_jsonl() with OpenAI JSONL format | VERIFIED | 77 lines; produces {"messages": [...], "label": action} |
| `harness/hitl/__main__.py` | CLI with calibrate, export, ui subcommands | VERIFIED | 103 lines; subparsers for all three commands; _resolve_db_path helper |
| `harness/hitl/ui.py` | Gradio standalone UI | VERIFIED (substantive) | 427 lines >= min_lines 100; build_ui() exported; all structural elements present |
| `harness/pyproject.toml` | hitl optional dependency group | VERIFIED | `hitl = ["gradio>=6.0,<7.0"]` at line 38 |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `harness/hitl/router.py` | `harness/traces/store.py` | `request.app.state.trace_store` | WIRED | router.py lines 48-53 call `trace_store.query_hitl_queue`; lines 70-71 call `trace_store.write_correction` |
| `harness/main.py` | `harness/hitl/router.py` | `app.include_router(hitl_router)` | WIRED | main.py line 100: `app.include_router(hitl_router)` |
| `harness/hitl/calibrate.py` | `harness/traces/store.py` | `TraceStore.query_corrections + query_by_id` | WIRED | calibrate.py lines 27, 35 call `trace_store.query_corrections()` and `trace_store.query_by_id()` |
| `harness/hitl/export.py` | `harness/traces/store.py` | `TraceStore.query_corrections + query_by_id` | WIRED | export.py lines 25, 31 call `trace_store.query_corrections()` and `trace_store.query_by_id()` |
| `harness/hitl/__main__.py` | `harness/hitl/calibrate.py` | `from harness.hitl.calibrate import compute_calibration` | WIRED | __main__.py line 55 imports compute_calibration; called at line 63 |
| `harness/hitl/ui.py` | `harness/hitl/router.py` | `httpx.Client GET /admin/hitl/queue POST /admin/hitl/correct` | WIRED | ui.py lines 83-91 GET `/admin/hitl/queue`; line 257 POST `/admin/hitl/correct` |

### Requirements Coverage

| Requirement | Source Plans | Description | Status | Evidence |
|-------------|-------------|-------------|--------|---------|
| HITL-01 | 10-01, 10-03 | Gradio dashboard shows a priority-sorted review queue of flagged requests | SATISFIED | GET /admin/hitl/queue returns priority-sorted results (store.py sort key); Gradio queue_table in ui.py shows priority column with computed scores |
| HITL-02 | 10-01, 10-03 | Reviewers can see diff-view of original vs critique-revised outputs | SATISFIED | select_item() in ui.py lines 206-243 parses cai_critique and generates difflib.unified_diff; cai_critique=None handled with "Blocked before revision" label |
| HITL-03 | 10-02 | Reviewer corrections feed back into threshold calibration and fine-tuning data | SATISFIED | compute_calibration() returns per-rail threshold suggestions; export_jsonl() writes OpenAI JSONL; both accessible via CLI |
| HITL-04 | 10-01 | Dashboard works headlessly (API-only mode) when no UI is needed | SATISFIED | router.py has no gradio import; test_headless_api_mode passes; endpoints return data without Gradio installed |

All four HITL requirements claimed in plan frontmatter are satisfied. No orphaned requirements found — REQUIREMENTS.md maps all four IDs to Phase 10, and all four are covered.

### Anti-Patterns Found

No anti-patterns detected. Searched for: TODO/FIXME/XXX/HACK/PLACEHOLDER/placeholder/coming soon across all Phase 10 hitl files. Zero matches.

No stub implementations found: all methods have substantive bodies, all callbacks make real HTTP calls or database calls, all tests exercise real logic.

One note: `store.py` imports `redact as redact_text` from `harness.pii.redactor` — the function is actually named `redact` in the redactor module (confirmed at redactor.py line 105). The alias is correct and harmless; tests pass confirming PII redaction works.

### Human Verification Required

#### 1. Gradio Dashboard Visual Layout

**Test:** Launch `python -m harness.hitl ui --port 8501 --api-url http://localhost:8080 --api-key sk-test` and open http://localhost:8501.
**Expected:** Two-panel layout loads; left panel has Rail Type, Tenant, Time Range dropdowns, Hide Reviewed checkbox, Refresh Queue button, and queue dataframe. Right panel shows Original Output, Revised Output, Changes (diff) textboxes and Approve/Reject/Edit buttons.
**Why human:** Gradio UI visual layout and panel scaling cannot be verified from static code inspection.

#### 2. Side-by-Side Diff View With cai_critique

**Test:** Select a queue item from a trace that has cai_critique data populated.
**Expected:** Original Output textbox shows `cai_critique.original_output`; Revised Output shows `cai_critique.revised_output`; Changes (diff) textbox shows unified diff lines.
**Why human:** Requires a live database with real trace records and a running harness API to test the full select_item callback path.

#### 3. Blocked-Before-Revision Fallback View

**Test:** Select a queue item from a trace where cai_critique is null.
**Expected:** Original Output shows the trace's response field. Revised Output shows "(Blocked before revision - no revised output available)".
**Why human:** Requires a real trace record with cai_critique=null in the database to exercise this branch at runtime.

#### 4. Full Correction Round-Trip

**Test:** Select a queue item, click Approve. Then click Refresh Queue.
**Expected:** Status textbox shows "OK — approve submitted for \<request_id\>". After refresh, the item's Status column shows "approve" and sorts below unreviewed items.
**Why human:** Requires live harness API, Gradio event loop, and database write to complete the correction round-trip and observe the queue re-sort.

### Gaps Summary

No gaps. All automated checks pass. The four human verification items above are runtime/visual confirmations of the Gradio UI layer — the underlying API, store, calibration, and export code is fully implemented and tested with 29 passing tests.

The phase goal is achieved at the code level. Operators have:
- A priority-sorted HITL queue via GET /admin/hitl/queue (API-first, headless-capable)
- Correction submission via POST /admin/hitl/correct with PII redaction, 422 validation, and auth gating
- Calibration engine that turns corrections into per-rail threshold suggestions (MIN_CORRECTIONS=5 guard)
- OpenAI JSONL fine-tuning exporter
- Full Gradio dashboard (427-line ui.py) with two-panel layout, diff view, and approve/reject/edit workflow

---

_Verified: 2026-03-23T07:45:00Z_
_Verifier: Claude (gsd-verifier)_
