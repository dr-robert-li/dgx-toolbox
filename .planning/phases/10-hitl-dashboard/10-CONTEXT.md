# Phase 10: HITL Dashboard - Context

**Gathered:** 2026-03-23
**Status:** Ready for planning

<domain>
## Phase Boundary

Gradio review UI for flagged requests, priority-sorted queue, side-by-side diff view, corrections that feed back into threshold calibration and fine-tuning data, and headless API mode. This is the final phase of v1.1 Safety Harness.

</domain>

<decisions>
## Implementation Decisions

### Review queue design
- **Priority sorting by distance from threshold**: Priority = how close the highest rail score was to its threshold. Closer = more uncertain = review first. Uses existing RailResult scores from `guardrail_decisions` JSON in traces
- **Compact summary per item**: Timestamp, tenant, triggering rail name, priority score, truncated prompt (first 80 chars), action taken (blocked/critiqued/allowed). Color-coded by action type
- **Triple filter**: Dropdowns for rail type (injection, pii, toxicity, all), tenant (from tenants.yaml), and time range (last 1h, 24h, 7d, custom)
- **Reviewed items stay with status**: Reviewed items get a status badge (approved/rejected/edited) and drop to bottom of queue. A "hide reviewed" toggle filters them out. Preserves audit trail

### Correction workflow
- **Three actions with precise semantics**:
  - **Approve**: Revised output was correct, use as positive training example
  - **Reject**: Revision was wrong, flag for threshold tightening
  - **Edit**: Reviewer writes a better response, use edited version as gold standard
- **SQLite `corrections` table** in traces.db: `request_id`, `reviewer`, `action` (approve/reject/edit), `edited_response` (nullable), `created_at`, `trace_ref`. Extends TraceStore
- **CLI calibration command**: `python -m harness.hitl calibrate` reads corrections, computes optimal thresholds based on reviewer decisions, outputs suggested rails.yaml changes. User reviews and applies. Not automatic
- **JSONL fine-tuning export**: `python -m harness.hitl export --format jsonl` exports corrections as prompt/response/label tuples. Approved+edited = positive, rejected = negative. Standard format for any fine-tuning pipeline

### Headless API mode
- **API-first architecture**: Core logic lives in FastAPI endpoints (GET /admin/hitl/queue, POST /admin/hitl/correct). Gradio UI is a thin wrapper calling these same endpoints. Headless mode = just run the harness without starting Gradio. Same data, same corrections store
- **Gradio as separate process**: `python -m harness.hitl ui --port 8501` starts Gradio standalone, connecting to the running harness API. Can be started/stopped independently. Harness doesn't need Gradio installed to run

### Gradio UI layout
- **Two-panel master-detail**: Left panel = scrollable review queue list with filters at top. Right panel = detail view when item is selected (diff view, action buttons, metadata)
- **Side-by-side diff with highlights**: Two columns — original output (left) and critique-revised output (right). Changed text highlighted in green/red. Edit button below to modify the revised version

### Claude's Discretion
- Gradio component choices (gr.Dataframe vs gr.HTML for queue, gr.Code vs gr.Textbox for diff)
- Color scheme and styling
- Calibration algorithm (how corrections map to threshold suggestions)
- Review queue pagination (if needed for large queues)
- Fine-tuning export format details (OpenAI JSONL vs custom)
- Gradio port configuration

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Existing harness code (Phase 5-9 foundation)
- `harness/traces/store.py` — TraceStore with query methods and eval_runs/redteam_jobs tables; extend with corrections table
- `harness/traces/schema.sql` — SQLite DDL; add corrections table
- `harness/proxy/admin.py` — Admin router pattern; HITL endpoints follow this pattern
- `harness/critique/engine.py` — CritiqueEngine produces cai_critique data for diff view
- `harness/critique/analyzer.py` — Trace analysis + judge model pattern; calibration follows similar pattern
- `harness/config/rail_loader.py` — RailConfig with threshold fields; calibration suggests changes to these
- `harness/config/rails/rails.yaml` — Rail config that calibration output targets
- `harness/eval/__main__.py` — CLI entry point pattern for harness.hitl module
- `harness/main.py` — App lifespan and router registration
- `harness/pyproject.toml` — Dependencies; add gradio as optional

### Project context
- `.planning/PROJECT.md` — v1.1 Safety Harness milestone goals
- `.planning/REQUIREMENTS.md` — HITL-01 through HITL-04

No external specs — requirements fully captured in decisions above.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `harness/traces/store.py`: TraceStore — extend with corrections table + queue query
- `harness/proxy/admin.py`: Admin router — HITL endpoints follow same pattern
- `harness/critique/analyzer.py`: Pattern for reading traces + producing reports — calibration follows similar structure
- `harness/eval/__main__.py`: CLI module pattern for `python -m harness.hitl`

### Established Patterns
- SQLite for all persistent storage (WAL mode, aiosqlite)
- CLI via `python -m harness.{module}` pattern
- Admin endpoints at `/admin/*`
- YAML for configuration
- `app.state.*` for shared resources

### Integration Points
- `harness/traces/schema.sql` — Add `corrections` CREATE TABLE
- `harness/traces/store.py` — Add correction CRUD + priority queue query
- `harness/main.py` — Register HITL admin router
- `harness/pyproject.toml` — Add `gradio` as optional dependency in hitl extras group
- New `harness/hitl/` package for queue logic, corrections, calibration, Gradio UI, CLI

</code_context>

<specifics>
## Specific Ideas

- The queue query should JOIN traces with corrections to annotate reviewed status, and ORDER BY distance_from_threshold ASC (closest to threshold = highest priority)
- Gradio's `gr.Row` + `gr.Column` layout works well for two-panel master-detail
- The calibration command should reuse the judge model approach from Phase 7 tuning suggestions but with correction data instead of raw traces
- Fine-tuning export should match OpenAI's JSONL chat format: `{"messages": [{"role": "user", "content": ...}, {"role": "assistant", "content": ...}]}`

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 10-hitl-dashboard*
*Context gathered: 2026-03-23*
