# Phase 9: Red Teaming - Context

**Gathered:** 2026-03-23
**Status:** Ready for planning

<domain>
## Phase Boundary

garak one-shot vulnerability scanning, deepteam adversarial prompt generation from near-miss traces, async job dispatch with SQLite tracking, and dataset balance enforcement. Does NOT include HITL dashboard (Phase 10).

</domain>

<decisions>
## Implementation Decisions

### Async job dispatch
- **Lightweight in-process**: Use `asyncio.create_task()` + SQLite job tracking table. No Celery/Redis. Jobs run in the FastAPI process. Zero new infrastructure — sufficient for single-machine DGX Spark
- **SQLite `redteam_jobs` table** in traces.db: `job_id`, `type` (garak|deepteam), `status` (pending|running|complete|failed), `created_at`, `completed_at`, `result` (JSON). Extends existing TraceStore pattern
- **One job at a time**: Semaphore-gated. New job submission returns 409 Conflict if one is already running. Prevents resource contention on DGX Spark

### Adversarial generation (deepteam)
- **Near-miss traces** as input: Query traces where any rail score was above `critique_threshold` but below `threshold` (block). These are the cases that almost slipped through — most valuable for adversarial variants
- **LLM-based generation via judge model**: Send near-miss prompts to the judge model with instructions to generate adversarial variants (rephrase, obfuscate, encode). Same LiteLLM backend, no new model dependency
- **JSONL staging file** for pending review: Generated prompts written to `harness/eval/datasets/pending/deepteam-{timestamp}.jsonl`. User reviews, then promotes via CLI `python -m harness.redteam promote <file>` which copies to the active eval datasets directory. Simple, auditable, git-trackable

### Dataset balance
- **Configurable max % per category**: Config in YAML `max_category_ratio: 0.40` (no single category > 40% of dataset)
- **Reject entire batch on cap violation**: Balance check runs before writing. Rejects the full pending file with clear error showing which categories exceed the cap and by how much. User must rebalance or regenerate. Matches success criteria #4

### garak integration
- **Preset scan profiles**: Ship 2-3 profiles (quick, standard, thorough) with increasing probe coverage. User can also pass custom garak config. Profiles in YAML alongside other harness config
- **Subprocess CLI wrapper**: Call `garak` CLI via subprocess with JSON output parsing. Keeps garak as external dependency, avoids importing internals. Simpler to update garak independently

### Claude's Discretion
- garak preset profile probe selections (which probes in quick/standard/thorough)
- deepteam adversarial generation prompt engineering
- Near-miss trace query window (time range or count limit)
- Job result JSON schema details
- Admin endpoint auth for red team jobs (reuse tenant auth or separate)
- Promotion CLI UX details

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Existing harness code (Phase 5-8 foundation)
- `harness/traces/store.py` — TraceStore with query_by_timerange and eval_runs methods; extend with redteam_jobs
- `harness/traces/schema.sql` — SQLite DDL; add redteam_jobs table
- `harness/proxy/admin.py` — Admin router pattern for red team job endpoints
- `harness/critique/engine.py` — CritiqueEngine with judge model access; deepteam reuses judge model
- `harness/critique/analyzer.py` — Trace analysis pattern; deepteam follows similar pattern
- `harness/eval/replay.py` — Replay harness; generated prompts feed into eval datasets after promotion
- `harness/eval/datasets/safety-core.jsonl` — JSONL dataset format; promoted prompts match this schema
- `harness/config/constitution.yaml` — Constitution config; judge_model field reused for deepteam
- `harness/main.py` — App lifespan and router registration
- `harness/pyproject.toml` — Dependencies; add garak

### Project context
- `.planning/PROJECT.md` — v1.1 Safety Harness milestone goals
- `.planning/REQUIREMENTS.md` — RDTM-01 through RDTM-04

No external specs — requirements fully captured in decisions above.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `harness/traces/store.py`: TraceStore with SQLite WAL — extend with redteam_jobs table + near-miss query
- `harness/critique/analyzer.py`: Pattern for reading traces + calling judge model — deepteam follows same pattern
- `harness/proxy/admin.py`: Admin router for POST endpoints — red team job API follows this
- `harness/eval/datasets/safety-core.jsonl`: JSONL schema for eval datasets — promoted prompts match this
- `harness/eval/metrics.py`: compute_metrics pattern — garak report parsing follows similar structure

### Established Patterns
- SQLite for all persistent storage (WAL mode, aiosqlite)
- CLI via `python -m harness.{module}` pattern
- YAML for configuration
- `app.state.*` for shared resources
- Admin endpoints at `/admin/*`

### Integration Points
- `harness/traces/schema.sql` — Add `redteam_jobs` CREATE TABLE
- `harness/traces/store.py` — Add job CRUD methods + near-miss query
- `harness/main.py` — Register red team router, init job semaphore
- `harness/pyproject.toml` — Add `garak` dependency
- `harness/eval/datasets/pending/` — Staging directory for generated prompts

</code_context>

<specifics>
## Specific Ideas

- deepteam generation is essentially: query near-misses → send to judge model with "generate adversarial variants" prompt → write to pending JSONL
- garak subprocess wrapper should capture both stdout (JSON report) and stderr (progress) and store in job result
- The promote command should run the balance check before copying to active datasets
- Near-miss query should filter by time range (configurable, default last 7 days) to focus on recent failures

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 09-red-teaming*
*Context gathered: 2026-03-23*
