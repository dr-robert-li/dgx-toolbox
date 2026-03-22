# Phase 7: Constitutional AI Critique - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Outputs that pass guardrails but score as high-risk trigger a two-pass critique-and-revise loop against a user-editable constitution. Low-risk outputs are never touched. The judge model can analyze trace history to produce actionable tuning suggestions. Does NOT include eval harness (Phase 8), red teaming (Phase 9), or HITL dashboard (Phase 10).

</domain>

<decisions>
## Implementation Decisions

### Risk gating logic
- High-risk determination uses **existing output rail scores** from Phase 6 (no separate risk classifier)
- Each output rail gets a `critique_threshold` in rails.yaml alongside its existing `threshold` — scores between `critique_threshold` and `threshold` (block) trigger the critique loop
- **Single-pass** critique: one critique + one revision. No iterative loops
- If revised output **still scores high-risk** after the single pass: fall back to hard block (reuse Phase 6 hard_block refusal pattern). Log both original and failed revision in trace

### Constitution design
- Constitution lives in `harness/config/constitution.yaml` — Pydantic-validated at startup (invalid file = harness refuses to start, matching Phase 6 rail config pattern)
- Principles are **categorized with priority weights**: grouped by category (safety, fairness, accuracy, helpfulness, etc.), each principle has a numeric priority weight
- **Per-principle `enabled: true/false` toggle** — users can disable specific principles without removing them. Matches per-rail toggle pattern from Phase 6
- Ships with **sensible defaults**: 10-15 default principles covering safety, fairness, accuracy, and helpfulness. User can modify, add, or remove

### Judge model config
- Judge model calls go **through LiteLLM** (same `http_client` as user requests). Swapping judge model = changing a model name string in config
- Default judge model = same model as the request. Configurable to a different model in constitution.yaml
- Critique calls **bypass guardrails** — they're internal and need to discuss problematic content. Separate code path that skips guardrails but still writes trace
- Critique prompt includes **only principles relevant to the triggering rail category** (rail-to-principle category mapping), not all enabled principles
- Judge outputs **structured JSON**: `{violated_principles: [...], critique: "...", revision: "...", confidence: 0.0-1.0}`. Parseable, storable in `cai_critique` trace field, feedable into Phase 8 evals

### Tuning suggestions (CSTL-05)
- **Batch analysis endpoint** — NOT per-request. User triggers on-demand. Keeps request latency unaffected
- Produces **threshold + principle tuning** suggestions: 1) rails with thresholds too high/low, 2) noisy principles (frequently trigger but rarely change outcomes), 3) missing principles for recurring issues. Ranked by impact
- Output: **both** human-readable ranked report with reasoning AND machine-readable YAML diffs the user can review and apply
- Exposed as **Python API + CLI wrapper**: core logic as `from harness.critique import analyze_traces`, exposed via POST /admin/suggest-tuning endpoint AND `python -m harness.critique analyze --since 24h`. Matches Phase 5 trace query pattern

### Claude's Discretion
- Critique prompt engineering (exact wording for judge model instructions)
- Default constitution principle text and categories
- Rail-to-principle category mapping specifics
- JSON schema for structured critique output
- Tuning suggestion ranking algorithm details
- Admin endpoint auth (whether /admin/* requires separate auth or reuses tenant auth)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Existing harness code (Phase 5-6 foundation)
- `harness/main.py` — FastAPI app factory with lifespan; judge model init goes here
- `harness/proxy/litellm.py` — Proxy route handler; critique loop inserts after output rails
- `harness/guards/engine.py` — GuardrailEngine with check_input/check_output; provides RailResult scores for risk gating
- `harness/guards/types.py` — GuardrailDecision and RailResult dataclasses; critique extends this
- `harness/config/rail_loader.py` — RailConfig Pydantic model; add critique_threshold field here
- `harness/config/rails/rails.yaml` — Rail config; add critique_threshold per output rail
- `harness/traces/store.py` — TraceStore with `cai_critique` field (currently null, ready for Phase 7)
- `harness/config/loader.py` — TenantConfig; may need judge model override per tenant

### Project context
- `.planning/PROJECT.md` — v1.1 Safety Harness milestone goals
- `.planning/REQUIREMENTS.md` — CSTL-01 through CSTL-05

No external specs — requirements fully captured in decisions above.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `harness/guards/engine.py`: GuardrailEngine.check_output() returns GuardrailDecision with all_results — provides rail scores for risk gating
- `harness/guards/types.py`: RailResult dataclass has `score` and `threshold` fields — critique_threshold extends this pattern
- `harness/config/rail_loader.py`: RailConfig Pydantic model with strict validation — extend for critique_threshold
- `harness/traces/store.py`: `cai_critique` TEXT column already exists in schema (nullable) — ready for JSON critique output
- Phase 6 hard_block refusal pattern: `_build_hard_block_refusal()` in engine.py — reuse for critique fallback

### Established Patterns
- Pydantic for config validation (RailConfig, TenantConfig)
- YAML for all configuration files
- `app.state.*` for shared resources in lifespan
- BackgroundTask for trace writes
- Module-level init for NeMo (nest_asyncio constraint)
- Per-rail granularity for thresholds and toggles

### Integration Points
- `harness/proxy/litellm.py:chat_completions()` — Insert critique loop after output rails pass but before response delivery
- `harness/proxy/litellm.py:_write_trace()` — Populate `cai_critique` field with structured JSON from judge
- `harness/main.py:lifespan()` — Initialize constitution loader and judge model config at startup
- `harness/config/rails/rails.yaml` — Add `critique_threshold` to each output rail

</code_context>

<specifics>
## Specific Ideas

- The critique loop sits between output rails and response delivery: output rails pass → check if any score exceeds critique_threshold → if yes, send to judge → return revision or hard block
- Critique calls must bypass guardrails (internal calls discussing problematic content would self-block)
- The `cai_critique` trace field is already nullable TEXT in SQLite — store the structured JSON from judge model directly
- Tuning analysis is a separate on-demand flow, not part of the request pipeline

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 07-constitutional-ai-critique*
*Context gathered: 2026-03-22*
