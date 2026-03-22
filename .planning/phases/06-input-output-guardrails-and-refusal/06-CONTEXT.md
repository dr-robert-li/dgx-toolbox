# Phase 6: Input/Output Guardrails and Refusal - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

All requests are screened before the model and all outputs are screened before delivery, with user-configurable per-rail thresholds and three distinct refusal modes, using Unicode-normalized input so guardrail evasion via encoding tricks is impossible. Does NOT include constitutional AI critique (Phase 7), eval harness (Phase 8), red teaming (Phase 9), or HITL dashboard (Phase 10).

</domain>

<decisions>
## Implementation Decisions

### Rail configuration model
- Global defaults in `harness/config/rails/rails.yaml`, tenants override specific thresholds in `tenants.yaml`
- Each rail has its own `enabled: true/false` + `threshold` + `refusal_mode` in config — per-rail granularity, not grouped by category
- Strict Pydantic validation at startup: invalid config = harness refuses to start with clear error message
- Single config directory: `harness/config/rails/` contains both `rails.yaml` and NeMo Colang `.co` files together (NeMo expects `config_path` pointing to a directory with both)

### Refusal modes
- Refusal mode is set **per-rail** in config (not per-tenant): content filter can hard-block while PII input can soft-steer
- **Hard block (REFU-01)**: Return a principled refusal response; model is never called (input) or response is replaced (output)
- **Soft steer (REFU-02)**: Flagged prompt is sent to the model with a system instruction to reformulate safely — LLM rewrite, not template. Adds latency for a second model call
- **Informative (REFU-03)**: Refusal names the violated policy, explains why, and suggests an adjacent allowed query. Specific and helpful, not generic
- Trace records full refusal detail: `refusal_mode` (hard_block/soft_steer/informative), triggering rail name, original prompt (redacted), rewritten prompt (if soft-steer)

### Pipeline wiring
- Guardrails execute **inline** in the proxy route handler, not as middleware
- Full pipeline: auth → rate limit → **Unicode normalize** → **INPUT RAILS** → proxy to LiteLLM → **OUTPUT RAILS** → response to client → background trace write
- Input rails block before LiteLLM — blocked requests never reach the model
- Output rails run **synchronously before delivery** — unsafe content never reaches the client
- When multiple input rails fail, **run all rails and report all violations** (not fail-fast). Return all violations in the refusal response
- `guardrail_decisions` trace field stores **all rails that ran** (pass + fail): JSON array of `{rail, result, score, threshold}` for every enabled rail. Full audit trail for eval/red teaming
- Bypass tenants (from Phase 5) skip the entire guardrail pipeline — auth and trace still apply

### Prompt injection and evasion detection
- **Unicode normalization (INRL-01)**: NFC/NFKC normalization + strip zero-width characters + confusables.txt lookup for homoglyphs. Log detected evasion attempts in trace even when normalization neutralizes them (signal for Phase 9 red teaming)
- **Prompt injection (INRL-04)**: Two-layer detection — fast regex heuristics for known patterns ("ignore previous instructions", encoded payloads) + NeMo Guardrails built-in jailbreak detection rail (LLM-as-judge) for sophisticated attacks
- **Jailbreak-success output detection (OURL-02)**: NeMo output self-check rails — same framework for both input and output sides
- **Threshold configurability**: Per-tenant injection sensitivity in tenant config (strict/balanced/permissive) — matches existing `pii_strictness` pattern from Phase 5

### Claude's Discretion
- NeMo Guardrails Colang flow definitions (specific rail implementations)
- Unicode confusables.txt source and update strategy
- Exact regex patterns for heuristic prompt injection detection
- NeMo LLM-as-judge prompt engineering for injection detection
- Output toxicity detection approach (NeMo built-in vs external classifier)
- Soft-steer system prompt wording for LLM rewrite

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Existing harness code (Phase 5 foundation)
- `harness/main.py` — FastAPI app factory with lifespan, where guardrail initialization must happen
- `harness/proxy/litellm.py` — Proxy route handler where input/output rails must be wired inline
- `harness/pii/redactor.py` — Existing PII redaction (regex + Presidio), input PII rail may reuse this
- `harness/guards/nemo_compat.py` — NeMo compatibility module, confirmed working on aarch64
- `harness/config/loader.py` — TenantConfig Pydantic model, must be extended with rail overrides
- `harness/config/tenants.yaml` — Tenant config, must add per-tenant rail threshold overrides
- `harness/traces/store.py` — TraceStore with guardrail_decisions field (currently null)

### Project context
- `.planning/PROJECT.md` — v1.1 Safety Harness milestone goals and constraints
- `.planning/REQUIREMENTS.md` — INRL-01 through INRL-05, OURL-01 through OURL-04, REFU-01 through REFU-04

No external specs — requirements fully captured in decisions above.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `harness/pii/redactor.py`: Two-layer PII detection (regex + Presidio) — INRL-03 input PII rail can reuse or wrap this
- `harness/guards/nemo_compat.py`: Confirmed NeMo Guardrails works on aarch64 — ready for actual rail implementation
- `harness/config/loader.py`: Pydantic-based TenantConfig with `load_tenants()` — extend with rail overrides
- `harness/traces/store.py`: TraceStore with `guardrail_decisions` (TEXT, nullable) and `refusal_event` (INTEGER) fields ready

### Established Patterns
- Pydantic for config validation (TenantConfig model in loader.py)
- YAML for all configuration (tenants.yaml)
- BackgroundTask for trace writes (non-blocking after response)
- `app.state.*` for shared resources in lifespan (http_client, trace_store, rate_limiter)
- Module-level init for NeMo (nest_asyncio conflict with uvicorn)

### Integration Points
- `harness/proxy/litellm.py:chat_completions()` — Insert normalize + input rails before LiteLLM call, output rails after
- `harness/proxy/litellm.py:_write_trace()` — Populate `guardrail_decisions` and `refusal_event` fields
- `harness/main.py:lifespan()` — Initialize NeMo LLMRails, load rail configs at startup
- `harness/config/tenants.yaml` — Add per-tenant rail override fields

</code_context>

<specifics>
## Specific Ideas

- NeMo Guardrails must be instantiated at module level before uvicorn starts (nest_asyncio conflict — confirmed in Phase 5 research, see nemo_compat.py docstring)
- Homoglyph detection should log evasion attempts even when normalization neutralizes them — provides signal for Phase 9 red teaming
- Soft-steer LLM rewrite uses the same LiteLLM backend as the main proxy (no separate model needed)
- The existing `pii_strictness` per-tenant pattern (strict/balanced/minimal) should be the template for all per-tenant threshold overrides

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 06-input-output-guardrails-and-refusal*
*Context gathered: 2026-03-22*
