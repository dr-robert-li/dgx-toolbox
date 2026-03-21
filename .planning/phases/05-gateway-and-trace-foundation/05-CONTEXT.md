# Phase 5: Gateway and Trace Foundation - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

FastAPI gateway with auth, per-tenant rate limiting, LiteLLM proxying, PII-safe JSONL trace store in SQLite, and NeMo Guardrails aarch64 compatibility validation. This is the first Python component in the repo. Does NOT include guardrail logic, constitutional AI critique, streaming, evals, or red teaming — those are Phase 6+.

</domain>

<decisions>
## Implementation Decisions

### Auth & tenant model
- API keys stored in YAML config file: `harness/config/tenants.yaml` with tenant_id, api_key_hash (bcrypt or argon2), rate limits, allowed models, bypass flag
- Bearer token format: standard `Authorization: Bearer sk-...` header — compatible with OpenAI client libraries
- Rate limiting: per-tenant RPM (requests per minute) + TPM (tokens per minute) with configurable limits per tenant
- Rate limiter uses sliding window — in-memory counter (no Redis dependency for v1)
- Auth is ALWAYS enforced — even on bypass routes

### Bypass routing
- Two mechanisms for bypass:
  1. Per-tenant config: `bypass: true` in tenants.yaml — tenant always skips guardrails/critique
  2. Separate ports: harness on :5000, LiteLLM stays on :4000 as-is — users can manually point to :4000 for direct access
- When bypassing via per-tenant config: auth still enforced, trace still logged, but guardrail/critique pipeline skipped
- When accessing LiteLLM directly on :4000: no harness involvement at all (existing behavior unchanged)

### PII redaction approach
- Two-layer detection: regex for structured PII (emails, phone numbers, SSNs, credit cards) + Microsoft Presidio NER for unstructured (names, addresses, medical terms)
- Replacement: type-specific tokens — `[EMAIL]`, `[PHONE]`, `[SSN]`, `[NAME]`, `[ADDRESS]`, etc.
- Strictness: configurable per-tenant — `pii_strictness: strict|balanced|minimal` in tenants.yaml
  - strict: over-redact (false positives OK)
  - balanced: reasonable precision
  - minimal: obvious PII only
- PII redaction runs BEFORE trace write — raw PII never touches the database

### Trace store design
- Storage: SQLite database at `harness/data/traces.db`
- Fields per record: request_id, tenant, timestamp, model, prompt (redacted), response (redacted), latency_ms, status_code, guardrail_decisions (JSON), cai_critique (JSON), refusal_event (boolean), bypass_flag (boolean)
- Retention: tiered — hot in SQLite (30 days default, configurable), then auto-export to JSONL files for long-term archive
- JSONL archive location: `harness/data/archive/traces-YYYY-MM.jsonl`
- Query interface: both Python API (`from harness.traces import TraceStore`) and CLI (`harness traces list --since ... --tenant ...`)
- Guardrail/critique fields are nullable (null when not yet implemented or when bypass)

### Claude's Discretion
- FastAPI project structure (harness/ package layout)
- SQLite schema details (indexes, column types)
- Presidio analyzer configuration (which entities to detect)
- Rate limiter implementation (token bucket vs sliding window)
- NeMo Guardrails compatibility test approach
- Harness port number (suggested :5000 but flexible)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Existing infrastructure
- `inference/start-litellm.sh` — LiteLLM proxy startup (port 4000), harness proxies to this
- `inference/setup-litellm-config.sh` — LiteLLM config generator, creates `~/.litellm/config.yaml`
- `docker-compose.inference.yml` — Inference stack compose (Open-WebUI + LiteLLM + vLLM)
- `lib.sh` — Shared function library (harness may need its own Docker/script launcher)

### Project context
- `.planning/PROJECT.md` — v1.1 Safety Harness milestone goals, constraints (aarch64, Python allowed for harness)
- `.planning/REQUIREMENTS.md` — GATE-01 through GATE-05, TRAC-01 through TRAC-04

No external specs — requirements fully captured in decisions above.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- LiteLLM on :4000 is already running and serves as the model backend — harness proxies to `http://localhost:4000/v1`
- `~/.litellm/config.yaml` defines available models — harness tenants reference these model names
- `docker-compose.inference.yml` can be extended with a `harness` service
- `example.bash_aliases` pattern for adding harness aliases

### Established Patterns
- Docker containers for services, bash scripts for launchers
- YAML for configuration (litellm config.yaml pattern)
- JSON for data (usage.json, audit.log patterns from modelstore)
- `set -euo pipefail` in scripts, `#!/usr/bin/env bash` shebangs

### Integration Points
- Harness :5000 ← clients (Open-WebUI can point to harness instead of LiteLLM)
- Harness :5000 → LiteLLM :4000 (proxy all model calls)
- `docker-compose.inference.yml` — add harness service
- `example.bash_aliases` — add harness aliases
- README — add Safety Harness section
- NVIDIA Sync custom app table — add harness entry

</code_context>

<specifics>
## Specific Ideas

- The harness should be a Python package (`harness/`) in the repo root, not inside a Docker container initially — develop and test locally first, containerize later
- NeMo Guardrails aarch64 compatibility must be validated BEFORE any guardrail code is written (Phase 5 success criteria #1) — this is a go/no-go gate for the entire guardrails approach
- Presidio's spaCy models for NER need to be tested on aarch64 as well

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 05-gateway-and-trace-foundation*
*Context gathered: 2026-03-22*
