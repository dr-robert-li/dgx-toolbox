# Phase 8: Eval Harness and CI Gate - Context

**Gathered:** 2026-03-23
**Status:** Ready for planning

<domain>
## Phase Boundary

Custom replay harness for safety/refusal scoring, lm-eval-harness integration for capability benchmarks with correct endpoint routing, CI gate that blocks on any regression, and stored results with trend visualization. Does NOT include red teaming (Phase 9) or HITL dashboard (Phase 10).

</domain>

<decisions>
## Implementation Decisions

### Replay dataset format
- **JSONL format**: Each line `{prompt, expected_action: "block"|"allow"|"steer", category: "injection"|"pii"|"toxicity"|..., description}`. One file per dataset (e.g., `safety-core.jsonl`, `refusal-edge-cases.jsonl`)
- Ships with **starter dataset**: 30-50 curated test cases covering injection, PII, toxicity, and benign baselines
- **Extended scoring metrics**: Standard classification (correct refusal rate, false refusal rate, F1) PLUS P50/P95 latency per request and critique trigger rate. Per-category breakdown
- **Full trace per case**: Each result includes actual `guardrail_decisions` JSON and `cai_critique` from the trace — enables debugging and feeds Phase 9 red teaming

### lm-eval routing
- **Custom lm-eval Model subclass**: Routes `generate_until()` through the harness gateway (:5000) and `loglikelihood()` directly to LiteLLM (:4000). Single lm-eval invocation handles both
- **Preconfigured benchmarks**: MMLU (knowledge), HellaSwag (reasoning), TruthfulQA (truthfulness), GSM8K (math). User can add more via lm-eval's task system
- **Unified results store**: Both replay and lm-eval results go to the same SQLite table with a `source` field (`replay`|`lm-eval`). Single source of truth for trends and CI gate

### CI gate design
- **Dual baseline comparison**: Default to previous-run comparison, but user can pin a named baseline via config. Both options available
- **CLI invocation**: `python -m harness.eval gate --tolerance 0.02` — runs replay + lm-eval, compares to baseline, exits 0 (pass) or 1 (fail). Integrable with any CI system
- **Comprehensive regression checks**: Safety (F1, correct refusal rate, false refusal rate) + capability (MMLU/HellaSwag/TruthfulQA/GSM8K scores) + latency (P95 response time). Any regression beyond tolerance blocks

### Results storage & trends
- **SQLite in existing traces.db**: New `eval_runs` table with `run_id`, `timestamp`, `source`, `metrics` (JSON), `config_snapshot` (JSON). Reuses existing TraceStore infrastructure and WAL mode
- **CLI text chart + JSON export**: `python -m harness.eval trends --last 20` prints ASCII sparkline charts in terminal + exports JSON for external tools. Works headlessly. Phase 10 HITL dashboard consumes the JSON

### Claude's Discretion
- lm-eval Model subclass implementation details (generate_until vs loglikelihood routing)
- ASCII chart library choice (or raw character drawing)
- Starter dataset prompt content and expected verdicts
- Baseline comparison algorithm (absolute vs relative tolerance)
- Config snapshot format in eval_runs table
- lm-eval installation approach (pip extra vs separate install)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Existing harness code (Phase 5-7 foundation)
- `harness/proxy/litellm.py` — Proxy route (POST /v1/chat/completions); replay harness sends requests here
- `harness/traces/store.py` — TraceStore with query methods; extend with eval_runs table
- `harness/traces/schema.sql` — SQLite DDL; add eval_runs table here
- `harness/proxy/admin.py` — Admin router pattern; eval endpoints may follow this pattern
- `harness/critique/analyzer.py` — Trace analysis pattern; replay harness follows similar pattern
- `harness/main.py` — App lifespan and router registration
- `harness/config/loader.py` — TenantConfig for auth in replay requests
- `harness/pyproject.toml` — Dependencies; add lm-eval-harness

### Project context
- `.planning/PROJECT.md` — v1.1 Safety Harness milestone goals
- `.planning/REQUIREMENTS.md` — EVAL-01 through EVAL-04

No external specs — requirements fully captured in decisions above.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `harness/traces/store.py`: TraceStore with SQLite WAL mode — extend with `eval_runs` table
- `harness/critique/analyzer.py`: Pattern for reading traces and producing reports — replay harness follows similar structure
- `harness/proxy/admin.py`: Admin router pattern for non-request endpoints
- `harness/config/tenants.yaml`: Test tenant API keys for replay harness auth

### Established Patterns
- SQLite for all persistent storage (WAL mode, aiosqlite)
- CLI via `python -m harness.{module}` pattern (critique already does this)
- Pydantic for config validation
- `app.state.*` for shared resources
- JSONL for data interchange

### Integration Points
- `harness/traces/schema.sql` — Add `eval_runs` CREATE TABLE
- `harness/traces/store.py` — Add `write_eval_run()` and `query_eval_runs()` methods
- `harness/pyproject.toml` — Add `lm-eval-harness` dependency
- New `harness/eval/` package for replay, lm-eval integration, CI gate, and trends

</code_context>

<specifics>
## Specific Ideas

- The replay harness should send requests to POST /v1/chat/completions with a real API key (test tenant), then read the trace to get full guardrail_decisions and cai_critique
- lm-eval's `local-chat-completions` model type may handle generative tasks out of the box; custom model class only needed for loglikelihood routing to :4000
- CI gate exit codes: 0 = pass, 1 = regression detected, 2 = eval error (couldn't run)
- Trend charts should show the last N runs with metric values and a visual indicator of direction (up/down arrow)

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 08-eval-harness-and-ci-gate*
*Context gathered: 2026-03-23*
