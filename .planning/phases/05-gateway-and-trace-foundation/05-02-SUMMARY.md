---
phase: 05-gateway-and-trace-foundation
plan: 02
subsystem: api
tags: [fastapi, presidio, aiosqlite, sqlite, pii-redaction, proxy, tracing, litellm]

# Dependency graph
requires:
  - phase: 05-01
    provides: "FastAPI app scaffold, auth (HTTPBearer + argon2), sliding-window rate limiter, conftest fixtures, pyproject.toml"

provides:
  - "POST /v1/chat/completions proxy route to LiteLLM with auth + rate limiting"
  - "PII redactor: regex pre-pass (email/phone/SSN/credit card) + Presidio NER, configurable strictness"
  - "TraceStore: async SQLite (WAL mode, 3 indexes) with write, query_by_id, query_by_timerange"
  - "start-harness.sh: bash launcher with configurable HARNESS_PORT and HARNESS_DATA_DIR"
  - "BackgroundTask trace write after response sent (latency unaffected)"
  - "Bypass tenant flag: skips future guardrail stage, still authenticates and logs trace"

affects: ["06-guardrails", "07-cai-critique", "08-eval-harness", "09-red-teaming"]

# Tech tracking
tech-stack:
  added:
    - "presidio-analyzer + presidio-anonymizer (Presidio NER PII detection)"
    - "aiosqlite (async SQLite trace store)"
    - "starlette BackgroundTask (post-response async execution)"
  patterns:
    - "Regex pre-pass before Presidio NER — structured PII caught even without spaCy model"
    - "BackgroundTask for trace write — decouples response latency from SQLite I/O"
    - "Module-level AnalyzerEngine() — eager load at import time, not per-request"
    - "TPM one-request lag: record_tpm post-response, check_tpm gates next request"
    - "app.state.trace_store injected in lifespan, accessed via request.app.state in route handler"

key-files:
  created:
    - harness/pii/redactor.py
    - harness/pii/__init__.py
    - harness/traces/store.py
    - harness/traces/__init__.py
    - harness/traces/schema.sql
    - harness/proxy/litellm.py
    - harness/proxy/__init__.py
    - harness/start-harness.sh
    - harness/data/.gitkeep
    - harness/data/archive/.gitkeep
    - harness/tests/test_pii.py
    - harness/tests/test_traces.py
    - harness/tests/test_proxy.py
  modified:
    - harness/main.py

key-decisions:
  - "Regex pre-pass handles structured PII without spaCy model — ensures email/phone/SSN/credit card always redacted even in minimal environments"
  - "BackgroundTask writes trace after JSONResponse sent — LiteLLM latency not inflated by SQLite write"
  - "TraceStore opens/closes aiosqlite connection per operation — safe for WAL mode concurrent readers"
  - "httpx.MockTransport used in test_proxy.py fixtures — no real LiteLLM needed in test suite"
  - "CLI trace query interface deferred — Python TraceStore API satisfies TRAC-04; CLI wrapper is Phase 6+ convenience layer"

patterns-established:
  - "Pattern: TDD RED→GREEN for all tasks — failing tests committed before implementation"
  - "Pattern: proxy_client fixture injects mock httpx transport and real TraceStore in tmp_path"
  - "Pattern: asyncio.sleep(0.2) after request in trace tests — allows BackgroundTask to complete"

requirements-completed: [GATE-01, GATE-04, GATE-05, TRAC-01, TRAC-02, TRAC-03, TRAC-04]

# Metrics
duration: 4min
completed: 2026-03-22
---

# Phase 05 Plan 02: Gateway and Trace Foundation Summary

**End-to-end gateway pipeline: Presidio PII redaction + aiosqlite WAL trace store + proxy route with BackgroundTask write, 38/38 tests passing (1 skipped — NeMo hardware gate)**

## Performance

- **Duration:** ~4 min
- **Started:** 2026-03-22T06:02:16Z
- **Completed:** 2026-03-22T06:06:27Z
- **Tasks:** 2
- **Files modified:** 14

## Accomplishments

- POST /v1/chat/completions proxies to LiteLLM, enforces auth and RPM/TPM rate limits, returns model response
- Every request writes a PII-redacted trace record to SQLite via BackgroundTask — raw PII never lands in the database
- TraceStore supports query_by_id and query_by_timerange with WAL mode and 3 indexes for Phase 8 eval and Phase 9 red teaming
- Bypass tenants (bypass=True) still authenticate and write traces with bypass_flag=1, ready for Phase 6 guardrail skip
- Launcher script start-harness.sh configurable via HARNESS_PORT and HARNESS_DATA_DIR

## Task Commits

Each task was committed atomically using TDD (RED test → GREEN implementation):

1. **Task 1 RED: Failing tests for PII redactor and trace store** - `016cc63` (test)
2. **Task 1 GREEN: PII redactor and trace store** - `ff20f1d` (feat)
3. **Task 2 RED: Failing tests for proxy route** - `16bc7ee` (test)
4. **Task 2 GREEN: Proxy route, bypass logic, background trace write, and launcher** - `3ef0c2a` (feat)

**Plan metadata:** (docs commit — recorded after summary)

_TDD tasks have separate RED and GREEN commits as per TDD execution flow._

## Files Created/Modified

- `harness/pii/redactor.py` — Regex pre-pass + Presidio NER PII redaction, STRICTNESS_ENTITIES map, typed token replacement
- `harness/pii/__init__.py` — Exports `redact`
- `harness/traces/store.py` — TraceStore class: init_db, write, query_by_id, query_by_timerange via aiosqlite
- `harness/traces/__init__.py` — Exports `TraceStore`
- `harness/traces/schema.sql` — SQLite DDL with PRAGMA journal_mode=WAL and 3 indexes
- `harness/proxy/litellm.py` — APIRouter with POST /v1/chat/completions, Depends(verify_api_key), BackgroundTask(_write_trace)
- `harness/proxy/__init__.py` — Package init
- `harness/main.py` — Added app.include_router(router), TraceStore init in lifespan, eager PII import
- `harness/start-harness.sh` — Bash launcher: set -euo pipefail, uvicorn harness.main:app, configurable HARNESS_PORT
- `harness/data/.gitkeep` — Data directory placeholder
- `harness/data/archive/.gitkeep` — Archive directory placeholder
- `harness/tests/test_pii.py` — 7 tests: email/phone/SSN/credit card redaction, strictness levels, no-PII unchanged
- `harness/tests/test_traces.py` — 5 tests: write/query_by_id, timerange, nullable fields, all fields, nonexistent ID
- `harness/tests/test_proxy.py` — 10 tests: proxy response, 401/403 auth, 429 RPM, trace write, PII in trace, bypass tenant

## Decisions Made

- Regex pre-pass before Presidio: ensures structured PII (email/phone/SSN/credit card) is caught even if en_core_web_lg is unavailable — regex runs first, Presidio NER runs second for unstructured PII
- BackgroundTask for trace write: SQLite I/O does not inflate the P50/P95 latency seen by the client
- httpx.MockTransport for test fixtures: all proxy tests are hermetic, no live LiteLLM required
- CLI trace interface deferred to a future phase: Python TraceStore API satisfies TRAC-04; the CLI wrapper is purely a convenience layer

## Deviations from Plan

None — plan executed exactly as written. All acceptance criteria met.

## Issues Encountered

None.

## User Setup Required

None — no external service configuration required. The test suite is fully hermetic using httpx.MockTransport and tmp_path SQLite databases.

## Next Phase Readiness

- Phase 6 (Input/Output Guardrails): proxy route is wired, bypass flag is set, guardrail_decisions and cai_critique fields are nullable in the schema — ready to plug in guardrail logic
- TraceStore query interface ready for Phase 8 eval harness and Phase 9 red teaming
- Full harness test suite: 38 passed, 1 skipped (NeMo hardware gate from Plan 03 — not affected by this plan)

---
*Phase: 05-gateway-and-trace-foundation*
*Completed: 2026-03-22*
