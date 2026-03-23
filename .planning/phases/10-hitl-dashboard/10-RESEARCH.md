# Phase 10: HITL Dashboard - Research

**Researched:** 2026-03-23
**Domain:** Gradio UI, FastAPI admin endpoints, SQLite corrections store, threshold calibration, fine-tuning export
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Review queue design**
- Priority sorting by distance from threshold: Priority = how close the highest rail score was to its threshold. Closer = more uncertain = review first. Uses existing RailResult scores from `guardrail_decisions` JSON in traces
- Compact summary per item: Timestamp, tenant, triggering rail name, priority score, truncated prompt (first 80 chars), action taken (blocked/critiqued/allowed). Color-coded by action type
- Triple filter: Dropdowns for rail type (injection, pii, toxicity, all), tenant (from tenants.yaml), and time range (last 1h, 24h, 7d, custom)
- Reviewed items stay with status: Reviewed items get a status badge (approved/rejected/edited) and drop to bottom of queue. A "hide reviewed" toggle filters them out. Preserves audit trail

**Correction workflow**
- Three actions with precise semantics:
  - Approve: Revised output was correct, use as positive training example
  - Reject: Revision was wrong, flag for threshold tightening
  - Edit: Reviewer writes a better response, use edited version as gold standard
- SQLite `corrections` table in traces.db: `request_id`, `reviewer`, `action` (approve/reject/edit), `edited_response` (nullable), `created_at`, `trace_ref`. Extends TraceStore
- CLI calibration command: `python -m harness.hitl calibrate` reads corrections, computes optimal thresholds based on reviewer decisions, outputs suggested rails.yaml changes. User reviews and applies. Not automatic
- JSONL fine-tuning export: `python -m harness.hitl export --format jsonl` exports corrections as prompt/response/label tuples. Approved+edited = positive, rejected = negative. Standard format for any fine-tuning pipeline

**Headless API mode**
- API-first architecture: Core logic lives in FastAPI endpoints (GET /admin/hitl/queue, POST /admin/hitl/correct). Gradio UI is a thin wrapper calling these same endpoints. Headless mode = just run the harness without starting Gradio. Same data, same corrections store
- Gradio as separate process: `python -m harness.hitl ui --port 8501` starts Gradio standalone, connecting to the running harness API. Can be started/stopped independently. Harness doesn't need Gradio installed to run

**Gradio UI layout**
- Two-panel master-detail: Left panel = scrollable review queue list with filters at top. Right panel = detail view when item is selected (diff view, action buttons, metadata)
- Side-by-side diff with highlights: Two columns — original output (left) and critique-revised output (right). Changed text highlighted in green/red. Edit button below to modify the revised version

### Claude's Discretion
- Gradio component choices (gr.Dataframe vs gr.HTML for queue, gr.Code vs gr.Textbox for diff)
- Color scheme and styling
- Calibration algorithm (how corrections map to threshold suggestions)
- Review queue pagination (if needed for large queues)
- Fine-tuning export format details (OpenAI JSONL vs custom)
- Gradio port configuration

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within phase scope.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| HITL-01 | Gradio dashboard shows a priority-sorted review queue of flagged requests | Gradio 6.x gr.Row/gr.Column two-panel layout; priority = distance from threshold computed from guardrail_decisions JSON in traces table |
| HITL-02 | Reviewers can see diff-view of original vs critique-revised outputs | cai_critique field in traces has original_output and revised_output; diff computed in Python using difflib or inline highlighting; rendered with gr.HTML or gr.Textbox |
| HITL-03 | Reviewer corrections feed back into threshold calibration and fine-tuning data | corrections table in SQLite; calibrate CLI reads corrections and suggests rails.yaml changes; export CLI writes OpenAI-format JSONL |
| HITL-04 | Dashboard works headlessly (API-only mode) when no UI is needed | API-first: GET /admin/hitl/queue, POST /admin/hitl/correct live in FastAPI; Gradio is a standalone optional process calling those endpoints |
</phase_requirements>

---

## Summary

Phase 10 is the final v1.1 Safety Harness phase. It adds a human-in-the-loop review layer on top of the existing trace infrastructure: a Gradio UI that reads flagged traces from SQLite (via new FastAPI endpoints), lets reviewers apply approve/reject/edit corrections, and exports that correction data for threshold calibration and fine-tuning.

The architecture is API-first. All HITL logic is in two FastAPI admin endpoints (`GET /admin/hitl/queue`, `POST /admin/hitl/correct`) that extend the existing `admin_router` pattern from `harness/proxy/admin.py`. Gradio runs as an independent process (`python -m harness.hitl ui`) that calls those endpoints over HTTP — it can be started and stopped independently of the harness. This ensures `HITL-04` (headless mode) is satisfied by design: the harness runs fine without Gradio installed.

The corrections table extends `traces.db` (schema.sql + TraceStore) following the same pattern as the `redteam_jobs` and `eval_runs` tables added in earlier phases. Calibration and export are CLI subcommands under `python -m harness.hitl`, following the `harness/eval/__main__.py` pattern.

**Primary recommendation:** Build `harness/hitl/` as a new package. Keep the FastAPI endpoints in `harness/hitl/router.py`, the Gradio UI in `harness/hitl/ui.py`, and the CLI in `harness/hitl/__main__.py`. Add `gradio` as an optional dependency under `[project.optional-dependencies] hitl = ["gradio>=6.0"]` in pyproject.toml.

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Gradio | >=6.0 (6.9.0 as of 2026-03-06) | Review UI | Official choice; gr.Row/gr.Column layout API stable across 5.x–6.x |
| FastAPI | >=0.115 (already pinned) | HITL admin endpoints | Already the project's web framework |
| aiosqlite | >=0.21 (already pinned) | corrections table persistence | Already used for all TraceStore operations |
| httpx | >=0.28 (already pinned) | Gradio process → harness HTTP calls | Already in project; sync client for Gradio callbacks |
| difflib | stdlib | Text diff for side-by-side view | No extra dependency; produces SequenceMatcher/ndiff output |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| pyyaml | >=6.0 (already pinned) | Write calibration suggestions as YAML diff | Already in project for config reading |
| argparse | stdlib | CLI subcommands (calibrate, export, ui) | Already used in eval/__main__.py |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| difflib (stdlib) | python-diff-match-patch | python-diff-match-patch produces richer word-level diffs but is an extra dependency; difflib is sufficient for line/word diff in Textbox display |
| gr.HTML for queue | gr.Dataframe | gr.Dataframe is simpler to wire but harder to color-code rows by action type; gr.HTML gives full CSS control; decision left to Claude's discretion |
| Sync httpx in Gradio | requests | Both work for sync callbacks; httpx already in project, no new dependency |

**Installation (optional extras group):**
```bash
pip install "dgx-harness[hitl]"
# or directly:
pip install "gradio>=6.0"
```

Add to pyproject.toml:
```toml
[project.optional-dependencies]
hitl = ["gradio>=6.0"]
```

---

## Architecture Patterns

### Recommended Project Structure
```
harness/hitl/
├── __init__.py          # empty or re-exports
├── __main__.py          # CLI: python -m harness.hitl calibrate|export|ui
├── router.py            # FastAPI APIRouter with /admin/hitl/* endpoints
├── store.py             # Correction CRUD + queue query (or extend TraceStore)
├── calibrate.py         # compute_calibration(corrections) -> yaml_diffs
├── export.py            # export_jsonl(corrections) -> list[dict]
└── ui.py                # Gradio app (standalone, calls harness HTTP API)
```

Schema changes:
```
harness/traces/schema.sql   # ADD corrections table DDL
harness/traces/store.py     # ADD write_correction(), query_corrections(), query_hitl_queue()
harness/main.py             # ADD: from harness.hitl.router import hitl_router; app.include_router(hitl_router)
harness/pyproject.toml      # ADD: hitl = ["gradio>=6.0"] optional dep group
```

### Pattern 1: corrections Table DDL
**What:** Extends traces.db with a corrections table. request_id is a FK reference to traces (logical, not enforced — SQLite FK enforcement is off by default in the project). reviewed status is derived by LEFT JOIN in the queue query.
**When to use:** Any correction write path.
**Example:**
```sql
-- Source: schema.sql extension pattern (eval_runs, redteam_jobs precedent)
CREATE TABLE IF NOT EXISTS corrections (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    request_id      TEXT NOT NULL,
    reviewer        TEXT NOT NULL,
    action          TEXT NOT NULL CHECK(action IN ('approve', 'reject', 'edit')),
    edited_response TEXT,
    created_at      TEXT NOT NULL,
    trace_ref       TEXT
);
CREATE INDEX IF NOT EXISTS idx_corrections_request_id ON corrections(request_id);
CREATE INDEX IF NOT EXISTS idx_corrections_created_at ON corrections(created_at);
```

### Pattern 2: Priority Queue Query
**What:** JOIN traces with corrections to annotate reviewed status; compute priority as (1.0 - distance_from_threshold) so closest-to-threshold items float to top; ORDER BY priority DESC.
**When to use:** GET /admin/hitl/queue endpoint.
**Example:**
```python
# Source: harness/traces/store.py pattern (query_near_misses precedent)
# SQL pre-filter for flagged traces (guardrail_decisions IS NOT NULL, status_code != 200 OR refusal_event=1 OR cai_critique IS NOT NULL)
# Python post-filter: parse guardrail_decisions JSON, extract highest rail score,
# compute distance = threshold - score, priority = -distance (closer = higher priority)
# LEFT JOIN corrections to get reviewed status per request_id
```

Priority formula (Python post-processing):
```python
def compute_priority(guardrail_decisions: dict) -> float:
    """Return priority score: higher = review sooner (closer to threshold)."""
    all_results = guardrail_decisions.get("all_results", [])
    if not all_results:
        return 0.0
    # Find the result with minimum distance from its threshold
    distances = []
    for r in all_results:
        score = r.get("score", 0.0)
        threshold = r.get("threshold", 1.0)
        if score > 0:
            distances.append(threshold - score)
    if not distances:
        return 0.0
    return 1.0 - min(distances)   # closer to threshold = higher priority score
```

### Pattern 3: FastAPI HITL Router
**What:** Follows `admin_router` pattern from `harness/proxy/admin.py`. Prefix `/admin/hitl`, auth via `verify_api_key` dependency.
**When to use:** All HITL API endpoints.
**Example:**
```python
# Source: harness/proxy/admin.py and harness/redteam/router.py patterns
from fastapi import APIRouter, Depends, Query, Request
from fastapi.responses import JSONResponse
from harness.auth.bearer import verify_api_key
from harness.config.loader import TenantConfig

hitl_router = APIRouter(prefix="/admin/hitl", tags=["hitl"])

@hitl_router.get("/queue")
async def get_queue(
    request: Request,
    tenant: TenantConfig = Depends(verify_api_key),
    rail: str = Query(default="all"),
    tenant_filter: str = Query(default="all"),
    since: str = Query(default="24h"),
    hide_reviewed: bool = Query(default=False),
):
    ...

@hitl_router.post("/correct")
async def submit_correction(
    request: Request,
    body: CorrectionRequest,
    tenant: TenantConfig = Depends(verify_api_key),
):
    ...
```

### Pattern 4: Gradio Standalone Process
**What:** Gradio runs as a separate Python process. It uses a sync `httpx.Client` (not async) to call harness API endpoints from Gradio event callbacks. Authentication uses an API key passed via env var or CLI arg.
**When to use:** `python -m harness.hitl ui --port 8501 --api-url http://localhost:8080 --api-key sk-xxx`
**Example:**
```python
# Source: Gradio layout guide (gradio.app/guides/controlling-layout)
import gradio as gr
import httpx

def build_ui(api_url: str, api_key: str) -> gr.Blocks:
    client = httpx.Client(base_url=api_url, headers={"Authorization": f"Bearer {api_key}"})

    with gr.Blocks(title="HITL Review Dashboard") as demo:
        with gr.Row():
            with gr.Column(scale=1):
                # Left panel: filter controls + queue list
                rail_filter = gr.Dropdown(choices=["all", "injection", "pii", "toxicity"], value="all", label="Rail")
                tenant_filter = gr.Dropdown(choices=["all"], label="Tenant")
                time_filter = gr.Dropdown(choices=["1h", "24h", "7d"], value="24h", label="Time Range")
                hide_reviewed = gr.Checkbox(label="Hide reviewed")
                queue_table = gr.Dataframe(headers=["ID", "Timestamp", "Tenant", "Rail", "Priority", "Action", "Prompt"])
            with gr.Column(scale=2):
                # Right panel: detail + diff view + correction actions
                original_box = gr.Textbox(label="Original Output", lines=10)
                revised_box = gr.Textbox(label="Revised Output", lines=10)
                reviewer_name = gr.Textbox(label="Reviewer", value="operator")
                edit_box = gr.Textbox(label="Edited Response (for Edit action)", lines=5, visible=False)
                with gr.Row():
                    approve_btn = gr.Button("Approve", variant="primary")
                    reject_btn = gr.Button("Reject", variant="stop")
                    edit_btn = gr.Button("Edit")
    return demo
```

### Pattern 5: CLI Entry Point
**What:** Follows `harness/eval/__main__.py` pattern exactly. `argparse` with subparsers for `calibrate`, `export`, `ui`.
**When to use:** `python -m harness.hitl <subcommand>`
**Example:**
```python
# Source: harness/eval/__main__.py pattern
import argparse, asyncio, sys

def main():
    parser = argparse.ArgumentParser(prog="python -m harness.hitl")
    subparsers = parser.add_subparsers(dest="command")

    cal = subparsers.add_parser("calibrate", help="Compute threshold suggestions from corrections")
    cal.add_argument("--db", default=None)
    cal.add_argument("--since", default="7d")

    exp = subparsers.add_parser("export", help="Export corrections as fine-tuning JSONL")
    exp.add_argument("--format", choices=["jsonl"], default="jsonl")
    exp.add_argument("--output", default="corrections.jsonl")
    exp.add_argument("--db", default=None)

    ui_p = subparsers.add_parser("ui", help="Start Gradio review UI")
    ui_p.add_argument("--port", type=int, default=8501)
    ui_p.add_argument("--api-url", default="http://localhost:8080")
    ui_p.add_argument("--api-key", default=None)

    args = parser.parse_args()
    if args.command == "calibrate":
        asyncio.run(_run_calibrate(args))
    elif args.command == "export":
        asyncio.run(_run_export(args))
    elif args.command == "ui":
        _run_ui(args)   # Gradio's launch() is sync
```

### Pattern 6: Fine-Tuning JSONL Export (OpenAI chat format)
**What:** Each correction emits one JSONL record. Approved and edited corrections are positive examples; rejected are negative (labeled separately or omitted depending on downstream use).
**When to use:** `python -m harness.hitl export --format jsonl`
**Example:**
```python
# Source: OpenAI fine-tuning cookbook (cookbook.openai.com/examples/how_to_finetune_chat_models)
# and CONTEXT.md decision: {"messages": [{"role": "user", ...}, {"role": "assistant", ...}]}
def correction_to_jsonl_record(trace: dict, correction: dict) -> dict:
    prompt = trace["prompt"]
    if correction["action"] == "edit":
        response = correction["edited_response"]
    else:
        # approved: use the revised output from cai_critique
        cai = trace.get("cai_critique") or {}
        response = cai.get("revised_output") or trace["response"]

    return {
        "messages": [
            {"role": "user", "content": prompt},
            {"role": "assistant", "content": response},
        ],
        "label": correction["action"],  # approve / edit / reject
    }
```

### Pattern 7: Calibration Algorithm
**What:** Reads corrections, groups by rail (from the trace's guardrail_decisions), computes the score distribution for approved vs rejected corrections, and suggests a threshold adjustment. Follows the `analyze_traces` judge pattern but uses correction data directly (no judge model call needed — corrections ARE the ground truth).
**When to use:** `python -m harness.hitl calibrate`
**Example logic (Claude's discretion on exact math):**
```
For each rail R:
  approved_scores = scores from traces where highest_rail == R and correction.action in ('approve', 'edit')
  rejected_scores = scores from traces where highest_rail == R and correction.action == 'reject'
  # Suggest threshold = midpoint between max(approved_scores) and min(rejected_scores)
  # or P95 of approved_scores if rejected set is empty
  suggested = (max(approved_scores, default=current) + min(rejected_scores, default=current)) / 2
  emit: {"rail": R, "current": current_threshold, "suggested": suggested, "reason": "..."}
```

### Anti-Patterns to Avoid
- **Automatic rails.yaml rewrite:** Calibration CLI outputs suggestions; user reviews and applies. Never auto-write config files.
- **Gradio importing inside FastAPI lifespan:** Gradio is optional and runs as a separate process. Never `import gradio` in harness/main.py or any non-hitl module.
- **Blocking the asyncio event loop in Gradio callbacks:** Gradio callbacks are sync; use `httpx.Client` (sync), not `httpx.AsyncClient`. Do not use `asyncio.run()` inside a callback that may already be inside an event loop.
- **Storing raw PII in corrections:** `edited_response` is user-entered text. Run through `redact()` before writing to the corrections table, consistent with TRAC-03 (PII redacted before trace write).
- **Mixing queue pagination state in FastAPI:** The queue endpoint should be stateless. Pagination (if needed) is offset/limit params, not server-side cursor state.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Text diff computation | Custom char-by-char diff | `difflib.unified_diff` or `difflib.SequenceMatcher` (stdlib) | SequenceMatcher handles opcodes (insert/delete/replace) correctly; edge cases in custom diff are subtle |
| JSONL serialization | Manual string formatting | `json.dumps(record)` per line | JSON serialization edge cases (escaping, Unicode) handled by stdlib |
| HTML diff highlighting | Custom HTML string builder | `difflib.HtmlDiff` or SequenceMatcher opcodes mapped to `<mark>` tags | HtmlDiff produces full HTML table; opcode approach gives more control for inline display |
| Gradio authentication | Custom session/cookie logic | Pass API key via env var to the Gradio process; include in every `httpx.Client` request header | Gradio is admin-only; env-var key is sufficient and consistent with existing auth pattern |

**Key insight:** The entire HITL stack is a thin orchestration layer over existing infrastructure. The traces are already there, the auth pattern is established, the CLI pattern is established. The new code is: one SQL table, two API endpoints, one Gradio layout, and two CLI subcommands.

---

## Common Pitfalls

### Pitfall 1: guardrail_decisions JSON shape assumptions
**What goes wrong:** Code assumes `all_results` always present or always non-empty in guardrail_decisions. Older traces may have a different shape (e.g., only `blocked` and `reason` fields from Phase 5 baseline before Phase 6 rails were added).
**Why it happens:** `guardrail_decisions` is a freeform JSON column. Shape evolved across phases.
**How to avoid:** Always use `.get("all_results", [])` with empty list default. Skip priority computation for traces with no all_results; assign priority=0.
**Warning signs:** `KeyError: 'all_results'` or `TypeError` in priority computation.

### Pitfall 2: Gradio version API churn
**What goes wrong:** Gradio moved from 4.x to 5.x to 6.x with UI API changes. Some component parameters changed names.
**Why it happens:** Gradio has been releasing major versions rapidly (5.0 in late 2024, 6.0 in early 2025, 6.9.0 as of March 2026).
**How to avoid:** Pin `gradio>=6.0,<7.0` in pyproject.toml. Verify component signatures against installed version at test time, not against training data. Key stable API: `gr.Blocks`, `gr.Row`, `gr.Column`, `gr.Dataframe`, `gr.Textbox`, `gr.Button`, `gr.Dropdown`, `gr.Checkbox` — all present and stable in 5.x–6.x.
**Warning signs:** `TypeError: __init__() got unexpected keyword argument` in Gradio component constructors.

### Pitfall 3: Sync httpx.Client in Gradio inside asyncio context
**What goes wrong:** If Gradio is ever run with async event handlers or inside an existing asyncio loop, using `httpx.AsyncClient` requires `await` which doesn't work in sync Gradio callbacks; using `asyncio.run()` inside a running loop raises `RuntimeError`.
**Why it happens:** Gradio event callbacks are synchronous by default. The harness uses asyncio internally but Gradio runs in its own process.
**How to avoid:** Always use `httpx.Client` (sync) inside Gradio callbacks. The Gradio process has no asyncio loop contention because it's a separate process.
**Warning signs:** `RuntimeError: This event loop is already running`.

### Pitfall 4: corrections table migration on existing traces.db
**What goes wrong:** `init_db()` calls `executescript(schema)` — if traces.db already exists from Phases 5–9, the new CREATE TABLE IF NOT EXISTS must not break existing data or indexes.
**Why it happens:** Schema changes on existing databases.
**How to avoid:** Use `CREATE TABLE IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS` (already the project pattern). Test by calling `init_db()` twice on the same db in tests — should be idempotent.
**Warning signs:** `sqlite3.OperationalError: table corrections already exists` — means IF NOT EXISTS was omitted.

### Pitfall 5: cai_critique field may be None for blocked traces
**What goes wrong:** The diff view tries to show `original_output` vs `revised_output` from `cai_critique`, but for hard-blocked traces (blocked before CAI ran), `cai_critique` is NULL.
**Why it happens:** CAI critique is risk-gated (CSTL-04) — only runs for outputs that passed initial threshold but exceeded critique_threshold. Hard-blocked inputs never reach CAI.
**How to avoid:** In the detail view, when `cai_critique` is None, show only the original output with a label "Blocked before revision — no revised output available." Hide the diff panel, show single-column view.
**Warning signs:** `NoneType has no attribute 'get'` on cai_critique access.

### Pitfall 6: Double PII exposure in edited_response
**What goes wrong:** A reviewer types a corrected response containing PII. It gets stored raw in corrections.edited_response, violating TRAC-03 spirit.
**Why it happens:** The corrections table is new; TRAC-03 was specified for the traces write path only.
**How to avoid:** In `write_correction()` in TraceStore (or hitl/store.py), run `edited_response` through `harness.pii.redactor.redact()` before INSERT, same as the trace write path.
**Warning signs:** SSNs, emails, etc. visible in exported JSONL.

---

## Code Examples

Verified patterns from existing codebase:

### TraceStore Extension Pattern (from store.py precedent)
```python
# Source: harness/traces/store.py (write_eval_run, create_job patterns)
async def write_correction(self, correction: dict) -> None:
    """Insert a correction record. Runs edited_response through PII redaction."""
    from harness.pii.redactor import redact
    edited = correction.get("edited_response")
    if edited:
        edited = redact(edited)
    async with aiosqlite.connect(self._db_path) as db:
        await db.execute(
            """
            INSERT INTO corrections
            (request_id, reviewer, action, edited_response, created_at, trace_ref)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                correction["request_id"],
                correction["reviewer"],
                correction["action"],
                edited,
                correction["created_at"],
                correction.get("trace_ref"),
            ),
        )
        await db.commit()
```

### Queue Query with Reviewed Status
```python
# Source: harness/traces/store.py query_near_misses + query_by_timerange patterns
async def query_hitl_queue(
    self, since: str, rail_filter: str = "all", tenant_filter: str = "all",
    hide_reviewed: bool = False, limit: int = 200
) -> list[dict]:
    """Fetch traces for HITL review, annotated with reviewed status."""
    async with aiosqlite.connect(self._db_path) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute(
            """
            SELECT t.*,
                   c.action  AS correction_action,
                   c.reviewer AS correction_reviewer
            FROM traces t
            LEFT JOIN corrections c ON c.request_id = t.request_id
            WHERE t.timestamp >= ?
              AND t.guardrail_decisions IS NOT NULL
              AND (? = 'all' OR t.tenant = ?)
            ORDER BY t.timestamp DESC
            LIMIT ?
            """,
            (since, tenant_filter, tenant_filter, limit),
        ) as cursor:
            rows = await cursor.fetchall()

    results = []
    for row in rows:
        record = dict(row)
        # Parse guardrail_decisions to compute priority
        gd = json.loads(record["guardrail_decisions"] or "{}")
        priority = compute_priority(gd)
        record["priority"] = priority

        # Rail filter (post-filter in Python — consistent with near_misses pattern)
        if rail_filter != "all":
            triggering_rail = _extract_triggering_rail(gd)
            if triggering_rail != rail_filter:
                continue

        # Hide reviewed filter
        if hide_reviewed and record.get("correction_action") is not None:
            continue

        results.append(record)

    # Sort by priority DESC (closest to threshold first), reviewed items last
    results.sort(key=lambda r: (r.get("correction_action") is not None, -r["priority"]))
    return results
```

### Admin Router Registration (main.py addition)
```python
# Source: harness/main.py existing pattern
from harness.hitl.router import hitl_router  # noqa: E402
app.include_router(hitl_router)
```

### _resolve_since reuse
```python
# Source: harness/proxy/admin.py _resolve_since — import and reuse directly
# In harness/hitl/router.py:
from harness.proxy.admin import _resolve_since
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Gradio 4.x `gr.Interface` | `gr.Blocks` for custom layouts | Gradio 4+ | Blocks is the standard for multi-component apps; Interface is for simple I/O only |
| Gradio embedded in FastAPI via mount_gradio_app | Gradio as standalone process | Project decision | Cleaner separation; harness doesn't need Gradio installed; aligns with HITL-04 |
| Manual SQL migration scripts | `CREATE TABLE IF NOT EXISTS` in schema.sql + `init_db()` | Established in project | Idempotent; no migration tooling needed for this project scale |

**Not applicable here:**
- Gradio 6.x introduced Svelte 5 component rewrites (internal), but the Python API for `gr.Row`, `gr.Column`, `gr.Dataframe`, `gr.Textbox`, `gr.Button` is stable and unchanged from 5.x.

---

## Open Questions

1. **guardrail_decisions shape for non-CAI traces (pre-Phase-6)**
   - What we know: Phase 5 traces have guardrail_decisions with a simpler shape (blocked/reason only, no all_results). Phase 9 redteam traces may also vary.
   - What's unclear: Whether the queue should show Phase 5-era traces at all (they have no per-rail scores to prioritize by).
   - Recommendation: Filter queue to traces where `json_extract(guardrail_decisions, '$.all_results')` IS NOT NULL, or handle gracefully with priority=0 fallback. The planner can decide whether to filter or include.

2. **Tenant list for filter dropdown**
   - What we know: tenants.yaml is loaded at startup into `app.state.tenants`. The queue API can return the list of tenants seen in traces.
   - What's unclear: Whether the Gradio UI should fetch tenant list from a dedicated endpoint or hardcode from a config file.
   - Recommendation: Add a `GET /admin/hitl/tenants` endpoint (or reuse the queue response's distinct tenant values) — keeps Gradio stateless.

3. **Calibration minimum sample size**
   - What we know: `analyze_traces` uses `MIN_SAMPLE_SIZE = 10`. The calibration CLI needs a similar guard.
   - What's unclear: Appropriate minimum for threshold suggestions from corrections (corrections are higher quality than raw traces, so maybe MIN=5 is sufficient).
   - Recommendation: Use MIN_CORRECTIONS = 5 per rail; document it clearly. Planner should note this as a constant in calibrate.py.

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | pytest 8.x + pytest-asyncio 0.25 |
| Config file | harness/pyproject.toml (`[tool.pytest.ini_options]`, `asyncio_mode = "auto"`) |
| Quick run command | `cd /home/robert_li/dgx-toolbox && python -m pytest harness/tests/test_hitl.py -x -q` |
| Full suite command | `cd /home/robert_li/dgx-toolbox && python -m pytest harness/tests/ -q` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| HITL-01 | Queue returns priority-sorted items; triple filter (rail, tenant, time) works; reviewed items drop to bottom | unit | `pytest harness/tests/test_hitl.py::test_queue_priority_sort -x` | ❌ Wave 0 |
| HITL-01 | GET /admin/hitl/queue returns 200 with correct shape, auth required | unit | `pytest harness/tests/test_hitl.py::test_queue_endpoint_auth -x` | ❌ Wave 0 |
| HITL-02 | cai_critique diff data extracted correctly; None cai_critique handled gracefully | unit | `pytest harness/tests/test_hitl.py::test_diff_extraction -x` | ❌ Wave 0 |
| HITL-03 | write_correction() inserts correct row; PII in edited_response is redacted | unit | `pytest harness/tests/test_hitl.py::test_write_correction_pii_redacted -x` | ❌ Wave 0 |
| HITL-03 | POST /admin/hitl/correct returns 200; queued item shows reviewed badge | unit | `pytest harness/tests/test_hitl.py::test_correct_endpoint -x` | ❌ Wave 0 |
| HITL-03 | export_jsonl produces valid OpenAI chat JSONL for approved and edited corrections | unit | `pytest harness/tests/test_hitl.py::test_export_jsonl_format -x` | ❌ Wave 0 |
| HITL-03 | calibrate returns yaml_diffs with suggested threshold per rail; respects MIN_CORRECTIONS guard | unit | `pytest harness/tests/test_hitl.py::test_calibrate_suggestions -x` | ❌ Wave 0 |
| HITL-04 | Harness starts and queue endpoint returns data without Gradio installed | unit | `pytest harness/tests/test_hitl.py::test_headless_api_mode -x` | ❌ Wave 0 |
| HITL-04 | corrections table DDL is idempotent (init_db() twice on same db) | unit | `pytest harness/tests/test_hitl.py::test_schema_idempotent -x` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `cd /home/robert_li/dgx-toolbox && python -m pytest harness/tests/test_hitl.py -x -q`
- **Per wave merge:** `cd /home/robert_li/dgx-toolbox && python -m pytest harness/tests/ -q`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `harness/tests/test_hitl.py` — covers HITL-01 through HITL-04 (all tests above)
- [ ] `harness/hitl/__init__.py` — package marker
- [ ] Framework install: `pip install "dgx-harness[hitl]"` — if Gradio not installed (UI tests must skip gracefully with `pytest.skip()` when gradio import fails, consistent with nemoguardrails/presidio pattern from Phase 5)

---

## Sources

### Primary (HIGH confidence)
- Existing codebase: `harness/traces/store.py`, `harness/traces/schema.sql`, `harness/proxy/admin.py`, `harness/critique/analyzer.py`, `harness/eval/__main__.py`, `harness/main.py`, `harness/pyproject.toml` — direct file reads, definitive for patterns
- [Gradio Docs — Controlling Layout](https://www.gradio.app/guides/controlling-layout) — gr.Row/gr.Column layout API
- [Gradio Docs — Row component](https://www.gradio.app/docs/gradio/row) — Row parameters
- [Gradio Docs — Column component](https://www.gradio.app/docs/gradio/column) — Column parameters

### Secondary (MEDIUM confidence)
- [gradio PyPI page](https://pypi.org/project/gradio/) — confirmed 6.9.0 as of 2026-03-06
- [OpenAI fine-tuning cookbook](https://cookbook.openai.com/examples/how_to_finetune_chat_models) — chat JSONL format with messages array
- [FastAPI + Gradio integration guide](https://www.gradio.app/guides/fastapi-app-with-the-gradio-client) — separate process architecture

### Tertiary (LOW confidence)
- None — all critical claims verified against codebase or official docs

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all libraries either already in project or verified via PyPI/official docs
- Architecture: HIGH — directly derived from existing codebase patterns (TraceStore, admin_router, eval CLI)
- Pitfalls: HIGH — derived from actual codebase inspection (cai_critique null cases, guardrail_decisions shape, project's asyncio/Gradio separation)
- Gradio component API: MEDIUM — verified against official docs; pinning `>=6.0,<7.0` mitigates version churn risk

**Research date:** 2026-03-23
**Valid until:** 2026-04-22 (30 days — Gradio API stable within pinned minor version range; SQLite/FastAPI patterns internal to project)
