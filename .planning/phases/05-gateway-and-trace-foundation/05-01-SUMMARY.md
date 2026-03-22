---
phase: 05-gateway-and-trace-foundation
plan: 01
subsystem: auth
tags: [fastapi, argon2, pydantic, httpx, sqlite, rate-limiting, python]

# Dependency graph
requires: []
provides:
  - FastAPI harness package scaffold (harness/) with pyproject.toml and build system
  - TenantConfig Pydantic model + load_tenants() YAML loader (harness/config/loader.py)
  - tenants.yaml with dev-team and ci-runner examples and argon2id hashes
  - HTTPBearer auth dependency with per-tenant argon2-cffi verify (harness/auth/bearer.py)
  - SlidingWindowLimiter with RPM (pre-request gate) + TPM (post-response record + pre-next check) (harness/ratelimit/sliding_window.py)
  - FastAPI app factory with lifespan: tenants, httpx AsyncClient pool, rate limiter (harness/main.py)
  - pytest fixtures: ASGITransport async_client, test_tenants, tmp_tenants_yaml (harness/tests/conftest.py)
  - 13 passing tests: 5 auth + 8 rate limit
affects:
  - 05-02 (proxy + trace store will import verify_api_key and SlidingWindowLimiter)
  - 05-03 (PII redactor wired before trace write uses TenantConfig.pii_strictness)
  - 06-xx (guardrails layer injects after auth + rate limit)

# Tech tracking
tech-stack:
  added:
    - fastapi>=0.115
    - uvicorn[standard]>=0.34
    - httpx>=0.28
    - pyyaml>=6.0
    - argon2-cffi>=25.1
    - aiosqlite>=0.21
    - presidio-analyzer>=2.2
    - presidio-anonymizer>=2.2
    - spacy>=3.8.5
    - pytest>=8.0
    - pytest-asyncio>=0.25
  patterns:
    - FastAPI lifespan context manager for app.state (tenants, http_client, rate_limiter)
    - HTTPBearer dependency injection for Bearer token auth
    - argon2-cffi PasswordHasher.verify() for timing-safe API key check
    - ASGITransport + pytest-asyncio for in-process FastAPI testing (no live server)
    - defaultdict(deque) sliding window: RPM pre-request gate, TPM post-response + pre-next check

key-files:
  created:
    - harness/pyproject.toml
    - harness/__init__.py
    - harness/main.py
    - harness/config/__init__.py
    - harness/config/loader.py
    - harness/config/tenants.yaml
    - harness/auth/__init__.py
    - harness/auth/bearer.py
    - harness/ratelimit/__init__.py
    - harness/ratelimit/sliding_window.py
    - harness/tests/__init__.py
    - harness/tests/conftest.py
    - harness/tests/test_auth.py
    - harness/tests/test_ratelimit.py
  modified: []

key-decisions:
  - "FastAPI 0.135 HTTPBearer returns 401 (not 403) for missing credentials — test updated to accept both (401|403) for forward compatibility"
  - "TPM limiting has one-request lag by design: record_tpm called post-response with actual token count; check_tpm gates the next request"
  - "SlidingWindowLimiter uses asyncio.Lock() not threading.Lock() — harness runs in single asyncio event loop under uvicorn"
  - "pyproject.toml uses setuptools>=61 build system with packages.find pointing where=['..'] to discover harness/ from repo root"

patterns-established:
  - "Pattern 1: app.state.tenants loaded at startup via lifespan — auth dependency reads from request.app.state.tenants at request time"
  - "Pattern 2: Each test creates its own SlidingWindowLimiter() — no shared state between tests"
  - "Pattern 3: conftest.py overrides app.state.tenants and app.state.rate_limiter before async_client yields — no real YAML parsed during tests"

requirements-completed: [GATE-02, GATE-03]

# Metrics
duration: 4min
completed: 2026-03-22
---

# Phase 5 Plan 01: Harness Scaffold, Auth, and Rate Limiter Summary

**FastAPI harness package with argon2id API key auth, per-tenant sliding window RPM/TPM rate limiting, and 13 passing pytest tests covering GATE-02 and GATE-03.**

## Performance

- **Duration:** 4 min
- **Started:** 2026-03-22T02:33:20Z
- **Completed:** 2026-03-22T02:36:59Z
- **Tasks:** 2
- **Files modified:** 14

## Accomplishments

- Full Python package scaffold: `harness/` with pyproject.toml, build system config, and all `__init__.py` files
- Pydantic TenantConfig model + load_tenants() YAML loader with schema validation and ValueError on malformed input
- HTTPBearer auth dependency using argon2-cffi for timing-safe API key verification against tenant hashes
- In-memory sliding window rate limiter: RPM pre-request gate + TPM post-response record with pre-next-request check
- FastAPI lifespan managing tenants, httpx AsyncClient pool (50 connections), and SlidingWindowLimiter
- pytest infrastructure: ASGITransport async_client fixture, test tenants with known keys, monkeypatch-based time control

## Task Commits

Each task was committed atomically:

1. **Task 1: Harness scaffold, config loader, and auth dependency** - `e86a70f` (feat)
2. **Task 2: Sliding window rate limiter tests and wire-up in main** - `639b98c` (feat)

## Files Created/Modified

- `harness/pyproject.toml` - Project metadata, deps, pytest config with asyncio_mode=auto
- `harness/main.py` - FastAPI app factory with lifespan: tenants + httpx client + rate limiter
- `harness/config/loader.py` - TenantConfig Pydantic model + load_tenants() with YAML parse + validation
- `harness/config/tenants.yaml` - dev-team and ci-runner examples with argon2id hashes
- `harness/auth/bearer.py` - verify_api_key dependency: HTTPBearer + argon2-cffi per-tenant check
- `harness/ratelimit/sliding_window.py` - SlidingWindowLimiter with check_rpm, check_tpm, record_tpm
- `harness/tests/conftest.py` - Shared fixtures: test_tenants, tmp_tenants_yaml, async_client (ASGITransport)
- `harness/tests/test_auth.py` - 5 auth tests: valid key, invalid key, missing auth, YAML load, bad YAML
- `harness/tests/test_ratelimit.py` - 8 rate limit tests: RPM gate, TPM gate, window sliding, isolation

## Decisions Made

- FastAPI 0.135 changed HTTPBearer to return 401 (not 403) for missing credentials. Test updated to accept both (401|403) for version tolerance.
- TPM limiting by design has one-request lag: tokens are unknown until the model responds, so check_tpm gates the next request using actual counts from the prior response.
- SlidingWindowLimiter uses asyncio.Lock() since harness runs under uvicorn's single asyncio event loop (not threading).
- pyproject.toml uses `setuptools>=61` with `packages.find where=['..']` so `harness.*` is discovered from the repo root.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Updated test for HTTPBearer 401 vs 403 behavior**
- **Found during:** Task 1 (test_auth.py GREEN phase)
- **Issue:** Plan specified test_missing_auth_returns_403 (FastAPI HTTPBearer default), but FastAPI 0.135+ returns 401 for missing credentials, not 403
- **Fix:** Renamed test to test_missing_auth_returns_401 and updated assertion to accept both (401|403) for forward compatibility
- **Files modified:** harness/tests/test_auth.py
- **Verification:** All 5 test_auth.py tests pass
- **Committed in:** e86a70f (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 - behavior difference in FastAPI version)
**Impact on plan:** Minor version-specific adaptation. No scope creep. Auth semantics are identical — missing credentials are rejected with an error response.

## Issues Encountered

- pyproject.toml initially lacked a `[build-system]` section and had an incorrect `setuptools.backends.legacy` backend path. Fixed to `setuptools.build_meta` with `setuptools>=61`.

## User Setup Required

None - no external service configuration required. All tests run in-process via ASGITransport.

## Next Phase Readiness

- Auth and rate limiter foundation complete — ready for Plan 05-02 (LiteLLM proxy route + trace store)
- `verify_api_key` and `SlidingWindowLimiter` importable from `harness.auth.bearer` and `harness.ratelimit`
- `app.state.tenants` and `app.state.rate_limiter` pattern established for downstream route handlers
- Integration tests (test_proxy.py) will require LiteLLM running on :4000 — document in 05-02 plan

---
*Phase: 05-gateway-and-trace-foundation*
*Completed: 2026-03-22*
