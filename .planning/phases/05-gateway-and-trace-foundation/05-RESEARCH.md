# Phase 5: Gateway and Trace Foundation - Research

**Researched:** 2026-03-22
**Domain:** FastAPI reverse proxy, NeMo Guardrails aarch64 validation, Microsoft Presidio PII redaction, aiosqlite trace store, in-memory rate limiting
**Confidence:** MEDIUM-HIGH (key dependencies verified against official sources; aarch64 build outcomes require runtime validation)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Auth & tenant model:**
- API keys stored in YAML config file: `harness/config/tenants.yaml` with tenant_id, api_key_hash (bcrypt or argon2), rate limits, allowed models, bypass flag
- Bearer token format: standard `Authorization: Bearer sk-...` header — compatible with OpenAI client libraries
- Rate limiting: per-tenant RPM (requests per minute) + TPM (tokens per minute) with configurable limits per tenant
- Rate limiter uses sliding window — in-memory counter (no Redis dependency for v1)
- Auth is ALWAYS enforced — even on bypass routes

**Bypass routing:**
- Two mechanisms for bypass:
  1. Per-tenant config: `bypass: true` in tenants.yaml — tenant always skips guardrails/critique
  2. Separate ports: harness on :5000, LiteLLM stays on :4000 as-is — users can manually point to :4000 for direct access
- When bypassing via per-tenant config: auth still enforced, trace still logged, but guardrail/critique pipeline skipped
- When accessing LiteLLM directly on :4000: no harness involvement at all (existing behavior unchanged)

**PII redaction approach:**
- Two-layer detection: regex for structured PII (emails, phone numbers, SSNs, credit cards) + Microsoft Presidio NER for unstructured (names, addresses, medical terms)
- Replacement: type-specific tokens — `[EMAIL]`, `[PHONE]`, `[SSN]`, `[NAME]`, `[ADDRESS]`, etc.
- Strictness: configurable per-tenant — `pii_strictness: strict|balanced|minimal` in tenants.yaml
  - strict: over-redact (false positives OK)
  - balanced: reasonable precision
  - minimal: obvious PII only
- PII redaction runs BEFORE trace write — raw PII never touches the database

**Trace store design:**
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

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| GATE-01 | User can send POST /v1/chat/completions through the gateway | FastAPI + httpx reverse proxy pattern covers this |
| GATE-02 | Auth via API key with per-tenant identity on each request | HTTPBearer dependency injection + argon2-cffi verify covers this |
| GATE-03 | Requests are rate-limited per tenant with configurable limits | In-memory sliding window RateLimiter class pattern covers this |
| GATE-04 | Gateway proxies to LiteLLM for model-agnostic invocation | httpx.AsyncClient with lifespan pooling to localhost:4000 covers this |
| GATE-05 | User can bypass harness and route directly to LiteLLM | bypass flag in tenants.yaml — skips guardrail stage, still logs trace |
| TRAC-01 | Every request/response logged as structured JSONL trace with request_id | aiosqlite write-on-response pattern covers this |
| TRAC-02 | Traces include guardrail decisions, CAI critique, refusal events | Nullable JSON columns in schema cover Phase 6+ fields |
| TRAC-03 | PII redacted from traces before writing | Presidio + regex pipeline runs before aiosqlite insert |
| TRAC-04 | Traces queryable via SQLite for eval and red teaming | aiosqlite SELECT with WHERE request_id / timestamp range covers this |
</phase_requirements>

---

## Summary

Phase 5 introduces the first Python component in DGX Toolbox: a FastAPI gateway that proxies to the existing LiteLLM instance, enforces per-tenant auth and rate limiting, and writes PII-redacted traces to SQLite. The phase has two parallel tracks: (1) building and verifying the gateway/trace infrastructure, and (2) validating NeMo Guardrails can be installed and initialized on DGX Spark aarch64 — a go/no-go gate for Phase 6.

The core technical risk is **NeMo Guardrails + Annoy on aarch64**. There are no pre-built PyPI wheels for Annoy on Linux aarch64; it must be built from source via `pip install` which requires gcc/g++. The good news is that spaCy 3.8.5+ now ships official aarch64 wheels (GitHub ARM runners became available January 2025), which resolves the previous blis build blocker for Microsoft Presidio on ARM.

The gateway itself follows a well-established FastAPI + httpx proxy pattern: a single shared `AsyncClient` created in the lifespan context manager proxies all requests to LiteLLM on :4000. Auth is a standard `HTTPBearer` dependency. The rate limiter is a pure-Python sliding window with a `defaultdict` of timestamp deques — no Redis. Traces write asynchronously through `aiosqlite` after the response is returned via a `BackgroundTask`.

**Primary recommendation:** Validate `pip install nemoguardrails` in a fresh aarch64 venv as Wave 0, Task 0. If Annoy fails to build from source despite gcc being present, fall back to installing annoy from conda-forge (`conda install -c conda-forge python-annoy`) before attempting the pip install. Everything else in Phase 5 (FastAPI, httpx, Presidio, aiosqlite) has confirmed aarch64 wheel availability.

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| fastapi | >=0.115 | ASGI web framework, routing, DI | De facto Python API standard; typed, async-native |
| uvicorn | >=0.34 | ASGI server | FastAPI's canonical server; no uvloop (incompatible with nest_asyncio) |
| httpx | >=0.28 | Async HTTP client for proxying to LiteLLM | FastAPI-recommended async client; connection pooling built in |
| pydantic | v2 (bundled with FastAPI >=0.115) | Request/response validation, settings | Zero extra install; schemas enforce contract |
| pyyaml | >=6.0 | Load tenants.yaml config | Standard Python YAML; yaml.safe_load() for security |
| argon2-cffi | >=25.1 | Hash and verify API keys | 2025 gold standard for password hashing; Argon2id by default |
| aiosqlite | >=0.21 | Async SQLite for trace store | asyncio bridge to stdlib sqlite3; no extra C dependencies |
| presidio-analyzer | >=2.2 | NER-based PII detection | Microsoft's production-grade PII engine; regex + spaCy |
| presidio-anonymizer | >=2.2 | Token replacement for PII | Paired package; replaces entities with typed tokens |
| spacy | >=3.8.5 | NLP engine for Presidio | 3.8.5+ has official aarch64 wheels (confirmed via GitHub issue #13622 resolution) |
| nemoguardrails | >=0.21 | LLMRails compatibility validation only in Phase 5 | NVIDIA's guardrails library; Phase 5 validates install only |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| pytest | >=8.0 | Test runner | All Python tests in this project |
| pytest-asyncio | >=0.25 | Async test support | Required for testing async FastAPI endpoints |
| httpx[asyncio] | bundled | ASGITransport for tests | Testing FastAPI without live server |
| python-multipart | >=0.0.12 | Form data (FastAPI dep) | FastAPI dependency for file/form handling |
| uvicorn[standard] | >=0.34 | Production server extras | Includes websockets; use in harness launch script |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| argon2-cffi | bcrypt | bcrypt is simpler but weaker against GPU attacks; argon2-cffi is preferred in 2025 |
| aiosqlite | SQLAlchemy async | aiosqlite is lighter; SQLAlchemy is overkill for a single-table trace store |
| presidio | custom regex only | Custom regex misses unstructured PII (names, addresses); Presidio NER handles those |
| in-memory rate limiter | Redis-backed (fastapi-limiter) | Redis adds a service dependency; in-memory is sufficient for single-process v1 |
| slidingwindow (custom) | fastapi-advanced-rate-limiter | Library adds complexity and version surface; custom sliding window is ~30 lines |

**Installation:**

```bash
# Create harness venv first, then:
pip install fastapi uvicorn[standard] httpx pyyaml argon2-cffi aiosqlite
pip install presidio-analyzer presidio-anonymizer
python -m spacy download en_core_web_lg
# NeMo Guardrails — must build Annoy from source on aarch64:
apt-get install -y gcc g++ python3-dev  # if not present
pip install nemoguardrails
```

---

## Architecture Patterns

### Recommended Project Structure

```
harness/                     # Python package root
├── __init__.py
├── main.py                  # FastAPI app factory + lifespan
├── config/
│   ├── __init__.py
│   ├── tenants.yaml         # Tenant definitions (auth, rate limits, bypass)
│   └── loader.py            # yaml.safe_load + Pydantic validation
├── auth/
│   ├── __init__.py
│   └── bearer.py            # HTTPBearer dependency, argon2 verify
├── ratelimit/
│   ├── __init__.py
│   └── sliding_window.py    # In-memory per-tenant sliding window
├── proxy/
│   ├── __init__.py
│   └── litellm.py           # httpx.AsyncClient passthrough to :4000
├── pii/
│   ├── __init__.py
│   └── redactor.py          # Presidio analyzer + anonymizer + regex layer
├── traces/
│   ├── __init__.py
│   ├── store.py             # TraceStore class: write, query, archive
│   └── schema.sql           # DDL for traces table
├── guards/
│   ├── __init__.py
│   └── nemo_compat.py       # Phase 5: import + instantiate LLMRails only
├── data/
│   ├── .gitkeep
│   └── archive/             # JSONL archive destination
├── tests/
│   ├── __init__.py
│   ├── conftest.py          # pytest fixtures (app client, temp db, mock tenants)
│   ├── test_auth.py
│   ├── test_ratelimit.py
│   ├── test_proxy.py
│   ├── test_pii.py
│   ├── test_traces.py
│   └── test_nemo_compat.py  # NeMo Guardrails validation test
├── pyproject.toml           # Build, deps, test config
└── start-harness.sh         # Bash launcher (mirrors start-litellm.sh pattern)
```

### Pattern 1: FastAPI Lifespan + httpx AsyncClient Pool

Initialize the httpx client once at startup and close on shutdown. Assign to `app.state` (not `app` object directly — use `request.app.state` in route handlers).

```python
# harness/main.py
from contextlib import asynccontextmanager
import httpx
from fastapi import FastAPI

LITELLM_BASE = "http://localhost:4000"

@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.http_client = httpx.AsyncClient(
        base_url=LITELLM_BASE,
        timeout=httpx.Timeout(120.0),
        limits=httpx.Limits(max_connections=50, max_keepalive_connections=20),
    )
    yield
    await app.state.http_client.aclose()

app = FastAPI(lifespan=lifespan)
```

### Pattern 2: HTTPBearer Auth Dependency

FastAPI's `HTTPBearer` extracts the Bearer token. The dependency verifies it against argon2-hashed values in tenants.yaml.

```python
# harness/auth/bearer.py
from fastapi import Depends, HTTPException, Request
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError

_ph = PasswordHasher()
_bearer = HTTPBearer()

def verify_api_key(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer),
    request: Request = None,
) -> dict:
    token = credentials.credentials
    # load tenant config (cached at startup via app.state.tenants)
    for tenant in request.app.state.tenants:
        try:
            _ph.verify(tenant["api_key_hash"], token)
            return tenant  # returns tenant dict with id, limits, bypass flag
        except VerifyMismatchError:
            continue
    raise HTTPException(status_code=401, detail="Invalid API key")
```

### Pattern 3: In-Memory Sliding Window Rate Limiter

Pure Python, thread-safe with asyncio.Lock. Stores per-tenant deque of timestamps.

```python
# harness/ratelimit/sliding_window.py
import time
import asyncio
from collections import defaultdict, deque

class SlidingWindowLimiter:
    def __init__(self):
        self._rpm_log: dict[str, deque] = defaultdict(deque)
        self._tpm_log: dict[str, deque] = defaultdict(deque)
        self._lock = asyncio.Lock()

    async def check(self, tenant_id: str, rpm_limit: int, tpm_limit: int, tokens: int) -> None:
        async with self._lock:
            now = time.monotonic()
            window = 60.0

            # RPM check
            rpm_q = self._rpm_log[tenant_id]
            while rpm_q and rpm_q[0] < now - window:
                rpm_q.popleft()
            if len(rpm_q) >= rpm_limit:
                raise RateLimitExceeded("RPM limit exceeded")
            rpm_q.append(now)

            # TPM check
            tpm_q = self._tpm_log[tenant_id]
            while tpm_q and tpm_q[0][0] < now - window:
                tpm_q.popleft()
            total_tokens = sum(t for _, t in tpm_q)
            if total_tokens + tokens > tpm_limit:
                raise RateLimitExceeded("TPM limit exceeded")
            tpm_q.append((now, tokens))
```

**Note:** Token count for TPM must be estimated before the request (use a tokenizer or heuristic) or counted post-response (check TPM on the response, reject on next request). Decide during planning which gate to use.

### Pattern 4: Proxy Route with Background Trace Write

Route handler proxies to LiteLLM, then writes trace in background after response is returned to client.

```python
# harness/proxy/litellm.py (route handler pseudocode)
from fastapi import BackgroundTask
from fastapi.responses import JSONResponse

@app.post("/v1/chat/completions")
async def chat_completions(request: Request, tenant: dict = Depends(verify_api_key)):
    # 1. Rate limit check (raises 429 if exceeded)
    await rate_limiter.check(tenant["id"], tenant["rpm"], tenant["tpm"], tokens=0)

    # 2. Proxy to LiteLLM
    body = await request.json()
    resp = await request.app.state.http_client.post(
        "/v1/chat/completions", json=body,
        headers={"Authorization": "Bearer none"},
    )

    # 3. PII redact + trace write (background, after response sent)
    response_data = resp.json()
    background = BackgroundTask(write_trace, request, tenant, body, response_data)
    return JSONResponse(content=response_data, background=background)
```

### Pattern 5: NeMo Guardrails Module-Level Initialization

The critical constraint: LLMRails MUST be instantiated at module load time — not inside an async handler. NeMo Guardrails applies `nest_asyncio` on import, which conflicts with uvicorn's event loop if initialization happens inside a running async task.

```python
# harness/guards/nemo_compat.py
# Source: NVIDIA NeMo Guardrails Issue #137 — module-level init is the verified workaround
from nemoguardrails import RailsConfig, LLMRails

# This MUST be at module level, before uvicorn.run() is called
_rails_config = RailsConfig.from_path("harness/config/rails/")
rails = LLMRails(_rails_config)  # instantiated once, reused per request
```

**Phase 5 scope:** The `nemo_compat.py` module exists only to confirm this import and instantiation succeeds on aarch64. No guardrail logic is added until Phase 6.

### Pattern 6: aiosqlite Trace Store

```python
# harness/traces/store.py
import aiosqlite
import json
import uuid
from datetime import datetime

class TraceStore:
    def __init__(self, db_path: str):
        self._db_path = db_path

    async def write(self, record: dict) -> None:
        async with aiosqlite.connect(self._db_path) as db:
            await db.execute("""
                INSERT INTO traces
                (request_id, tenant, timestamp, model, prompt, response,
                 latency_ms, status_code, guardrail_decisions, cai_critique,
                 refusal_event, bypass_flag)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                record["request_id"], record["tenant"],
                record["timestamp"], record["model"],
                record["prompt"], record["response"],
                record["latency_ms"], record["status_code"],
                json.dumps(record.get("guardrail_decisions")),
                json.dumps(record.get("cai_critique")),
                record.get("refusal_event", False),
                record.get("bypass_flag", False),
            ))
            await db.commit()

    async def query_by_id(self, request_id: str) -> dict | None:
        async with aiosqlite.connect(self._db_path) as db:
            db.row_factory = aiosqlite.Row
            async with db.execute(
                "SELECT * FROM traces WHERE request_id = ?", (request_id,)
            ) as cursor:
                row = await cursor.fetchone()
                return dict(row) if row else None

    async def query_by_timerange(self, since: str, until: str | None = None) -> list[dict]:
        # since/until are ISO8601 strings
        ...
```

### Anti-Patterns to Avoid

- **Initializing LLMRails inside an async handler:** Causes `RuntimeError: Cannot enter into task while another task is being executed`. Always initialize at module level.
- **Using uvloop:** `nest_asyncio` cannot patch uvloop's C extension; uvicorn must use the default asyncio event loop.
- **Opening a new aiosqlite connection per write:** The overhead is acceptable for traces (low-frequency) but avoid in hot-path code. Use a connection pool or WAL mode for concurrent readers.
- **Writing raw PII to a temp variable before redaction:** Always apply the Presidio pipeline before any variable that persists (log lines, trace records, even in-memory dicts that may be logged).
- **Sharing the httpx AsyncClient across test cases without resetting:** Each test should use an independent `ASGITransport` client.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| API key hash verification | Custom hash comparison | argon2-cffi `PasswordHasher.verify()` | Timing attack resistance, salt handling, algorithm versioning |
| PII entity detection (names, addresses, medical) | Custom NER model | presidio-analyzer + en_core_web_lg | Trained on 18+ entity types; regex alone misses unstructured PII |
| Async SQLite writes | sync sqlite3 in thread executor | aiosqlite | Correct asyncio integration; avoids event loop blocking |
| Bearer token extraction | Custom header parsing | `fastapi.security.HTTPBearer` | Handles malformed headers, missing headers, 401 auto-raise |
| Async HTTP proxying | raw socket or subprocess | httpx.AsyncClient | Connection pooling, timeout handling, keep-alive, streaming support |

**Key insight:** PII detection is an NLP problem, not a regex problem. Custom regex catches structured PII (SSNs, emails) but misses "John Smith at 123 Main St" in freeform text. Presidio's spaCy NER is the production solution.

---

## Common Pitfalls

### Pitfall 1: Annoy Build Failure on aarch64

**What goes wrong:** `pip install nemoguardrails` fails with `ERROR: Failed building wheel for annoy`. Annoy has no pre-built PyPI wheels for Linux aarch64.

**Why it happens:** Annoy is a C++ library. PyPI does not host manylinux aarch64 wheels for Annoy 1.17.3.

**How to avoid:**
1. Ensure `gcc`, `g++`, and `python3-dev` are installed: `apt-get install -y gcc g++ python3-dev`
2. If pip still fails, use conda-forge: `conda install -c conda-forge python-annoy`, then `pip install nemoguardrails --no-deps` followed by remaining deps
3. Alternatively, pin `annoy==1.17.3` explicitly before installing nemoguardrails (some users report success with explicit pin)

**Warning signs:** Error message contains "Failed building wheel for annoy" or "c++: error: unrecognized command line option".

### Pitfall 2: LLMRails Asyncio Conflict with Uvicorn

**What goes wrong:** `RuntimeError: Cannot enter into task <Task-1> while another task <Task-12> is being executed` on first request.

**Why it happens:** NeMo Guardrails applies `nest_asyncio.apply()` on import. When `LLMRails()` is called inside an async handler running under uvicorn's event loop, the nested asyncio state conflicts.

**How to avoid:** Import `nemoguardrails` and instantiate `LLMRails` at module top level, before `uvicorn.run()` is called. Never instantiate inside an async def.

**Warning signs:** Exception only on first request, subsequent requests pass. Stack trace shows `nest_asyncio` in the traceback.

### Pitfall 3: spaCy aarch64 Version Pinning

**What goes wrong:** `pip install presidio-analyzer` pulls spaCy >= 3.8.0 but fails to build blis on aarch64 if a version before 3.8.5 is resolved.

**Why it happens:** spaCy 3.8.0 - 3.8.4 lacked aarch64 wheels. GitHub ARM runners became available in January 2025 and spaCy 3.8.5 was the first release with official aarch64 wheels.

**How to avoid:** Pin `spacy>=3.8.5` explicitly in `pyproject.toml` before installing presidio. Download the model separately after install: `python -m spacy download en_core_web_lg`.

**Warning signs:** Build failure mentioning `blis/_src/make/linux-cortexa57.jsonl` not found.

### Pitfall 4: SQLite Write Blocking under Load

**What goes wrong:** Trace writes block request handling; P95 latency spikes.

**Why it happens:** aiosqlite runs in a single background thread; heavy trace writes with large prompts/responses can serialize.

**How to avoid:** Use `BackgroundTask` so the trace write happens after the response is sent to the client. This decouples latency measurement from write time. Also enable WAL mode: `PRAGMA journal_mode=WAL` in schema init.

**Warning signs:** Latency measurement in trace record is accurate but client-observed latency is higher.

### Pitfall 5: Per-Tenant TPM Counting Without Token Counts

**What goes wrong:** TPM rate limiter cannot enforce because token count is unknown until after the model responds.

**Why it happens:** Token count is in the response (`usage.total_tokens`), not the request.

**How to avoid:** Use a two-phase approach: estimate tokens from request body length (heuristic: chars / 4) for pre-request check, then use actual `usage.total_tokens` from the LiteLLM response to update the running TPM counter for subsequent requests. This is a post-request gate rather than a pre-request block.

**Warning signs:** TPM limit never triggers even when clearly exceeded.

### Pitfall 6: Raw PII in Background Task Variables

**What goes wrong:** PII appears in logs, tracebacks, or intermediate state even though the final trace is redacted.

**Why it happens:** Python tracebacks include local variable values; exception handlers may log the raw request body.

**How to avoid:** Apply Presidio redaction immediately when the request body is parsed, before assigning to any named variable. Do not store `raw_prompt` anywhere — only `redacted_prompt`.

---

## Code Examples

### Presidio PII Redaction with Per-Tenant Strictness

```python
# harness/pii/redactor.py
# Source: https://microsoft.github.io/presidio/analyzer/
from presidio_analyzer import AnalyzerEngine
from presidio_anonymizer import AnonymizerEngine
from presidio_anonymizer.entities import OperatorConfig

_analyzer = AnalyzerEngine()
_anonymizer = AnonymizerEngine()

STRICTNESS_ENTITIES = {
    "strict": [
        "PERSON", "EMAIL_ADDRESS", "PHONE_NUMBER", "US_SSN",
        "CREDIT_CARD", "LOCATION", "DATE_TIME", "IP_ADDRESS",
        "MEDICAL_LICENSE", "URL", "IBAN_CODE", "NRP",
    ],
    "balanced": [
        "PERSON", "EMAIL_ADDRESS", "PHONE_NUMBER", "US_SSN",
        "CREDIT_CARD", "LOCATION",
    ],
    "minimal": [
        "EMAIL_ADDRESS", "PHONE_NUMBER", "US_SSN", "CREDIT_CARD",
    ],
}

def redact(text: str, strictness: str = "balanced") -> str:
    entities = STRICTNESS_ENTITIES.get(strictness, STRICTNESS_ENTITIES["balanced"])
    results = _analyzer.analyze(text=text, entities=entities, language="en")
    anonymized = _anonymizer.anonymize(
        text=text,
        analyzer_results=results,
        operators={
            "PERSON": OperatorConfig("replace", {"new_value": "[NAME]"}),
            "EMAIL_ADDRESS": OperatorConfig("replace", {"new_value": "[EMAIL]"}),
            "PHONE_NUMBER": OperatorConfig("replace", {"new_value": "[PHONE]"}),
            "US_SSN": OperatorConfig("replace", {"new_value": "[SSN]"}),
            "CREDIT_CARD": OperatorConfig("replace", {"new_value": "[CREDIT_CARD]"}),
            "LOCATION": OperatorConfig("replace", {"new_value": "[ADDRESS]"}),
            "DEFAULT": OperatorConfig("replace", {"new_value": "[REDACTED]"}),
        },
    )
    return anonymized.text
```

### SQLite Schema with WAL Mode and Indexes

```sql
-- harness/traces/schema.sql
PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS traces (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    request_id      TEXT NOT NULL UNIQUE,
    tenant          TEXT NOT NULL,
    timestamp       TEXT NOT NULL,   -- ISO8601 UTC
    model           TEXT NOT NULL,
    prompt          TEXT NOT NULL,   -- PII-redacted
    response        TEXT NOT NULL,   -- PII-redacted
    latency_ms      INTEGER NOT NULL,
    status_code     INTEGER NOT NULL,
    guardrail_decisions TEXT,        -- JSON, NULL until Phase 6
    cai_critique    TEXT,            -- JSON, NULL until Phase 7
    refusal_event   INTEGER NOT NULL DEFAULT 0,  -- boolean
    bypass_flag     INTEGER NOT NULL DEFAULT 0   -- boolean
);

CREATE INDEX IF NOT EXISTS idx_traces_request_id ON traces(request_id);
CREATE INDEX IF NOT EXISTS idx_traces_timestamp  ON traces(timestamp);
CREATE INDEX IF NOT EXISTS idx_traces_tenant     ON traces(tenant);
```

### Tenants YAML Config Structure

```yaml
# harness/config/tenants.yaml
tenants:
  - tenant_id: dev-team
    api_key_hash: "$argon2id$v=19$m=65536,t=3,p=4$..."  # argon2-cffi hash of sk-devteam-xxx
    rpm_limit: 60
    tpm_limit: 100000
    allowed_models:
      - llama3.1
      - gemma3
    bypass: false
    pii_strictness: balanced

  - tenant_id: ci-runner
    api_key_hash: "$argon2id$v=19$m=65536,t=3,p=4$..."
    rpm_limit: 120
    tpm_limit: 500000
    allowed_models: ["*"]
    bypass: true    # CI always skips guardrails
    pii_strictness: minimal
```

### pytest Fixture for FastAPI Async Testing

```python
# harness/tests/conftest.py
# Source: https://fastapi.tiangolo.com/advanced/async-tests/
import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from harness.main import app

@pytest_asyncio.fixture
async def client():
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as ac:
        yield ac
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| spaCy 3.7.x only for aarch64 | spaCy 3.8.5+ has official aarch64 wheels | Jan 2025 (GitHub ARM runners) | Presidio NER works on DGX Spark without blis build failure |
| `@app.on_event("startup")` | `@asynccontextmanager async def lifespan(app)` | FastAPI 0.93 (2023), now standard | Single lifespan pattern replaces deprecated event decorators |
| `nest_asyncio` workaround notebooks | Module-level LLMRails init | NeMo Guardrails v0.14+ | Module-level init is the reliable pattern for uvicorn deployments |
| NeMo Guardrails v0.18 (Nov 2024) | v0.21.0 (Mar 2025) — LangChain 1.x compat, IORails | Mar 2025 | Latest stable; use this version for Phase 5 validation |
| bcrypt for password hashing | argon2-cffi (Argon2id) | Argon2 PHC winner 2015; gold standard by 2025 | Memory-hard; GPU-resistant; recommended for API key hashing |

**Deprecated/outdated:**
- `app.on_event("startup"/"shutdown")`: Replaced by lifespan context manager; still works but deprecated
- `nest_asyncio.apply()` workaround: Masked the real fix (module-level init); don't add explicit `nest_asyncio` calls
- spaCy < 3.8.5 on aarch64: Known build failure; pin 3.8.5+
- NeMo Guardrails < 0.19: Missing LangChain 1.x compat and IORails optimizations

---

## Open Questions

1. **Annoy aarch64 build outcome on actual DGX Spark hardware**
   - What we know: No PyPI wheels for Linux aarch64; must build from source with gcc
   - What's unclear: Whether DGX Spark's specific kernel/gcc version causes any build issues
   - Recommendation: Wave 0, Task 0 is a compatibility probe script that installs in a fresh venv and reports pass/fail. Provides go/no-go before writing any guardrail code.

2. **TPM estimation approach before model call**
   - What we know: Token counts come from `usage.total_tokens` in the LiteLLM response, not the request
   - What's unclear: Whether to use pre-request estimate (chars/4 heuristic) as a gate or post-request actual count as a retroactive gate for next request
   - Recommendation: Use post-request actual count updating the sliding window; enforce the limit on the subsequent request. Document that TPM limiting has one-request lag.

3. **Presidio model loading time at startup**
   - What we know: `en_core_web_lg` is ~700MB; first `AnalyzerEngine()` call loads the model
   - What's unclear: Whether to load the AnalyzerEngine eagerly at startup (adds ~2-3 seconds) or lazily on first PII request
   - Recommendation: Load eagerly in the lifespan context manager (alongside `http_client`) so latency is predictable and not incurred on first user request.

4. **Harness port assignment**
   - What we know: Context suggests :5000; STATE.md has a note to verify code-server is not on 8080; harness is NOT on 8080
   - What's unclear: Whether :5000 is in use on the target DGX Spark (Flask dev servers default to 5000)
   - Recommendation: Default to :5000 but make it configurable via environment variable `HARNESS_PORT`. Document that users should check `ss -tlnp | grep 5000` before starting.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | pytest 8.x + pytest-asyncio 0.25 |
| Config file | `harness/pyproject.toml` — see Wave 0 |
| Quick run command | `cd harness && python -m pytest tests/ -x -q` |
| Full suite command | `cd harness && python -m pytest tests/ -v` |

### Phase Requirements to Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| GATE-01 | POST /v1/chat/completions returns 200 with LiteLLM response | integration | `pytest tests/test_proxy.py -x` | Wave 0 |
| GATE-02 | Missing API key → 401; valid API key → tenant attached | unit | `pytest tests/test_auth.py -x` | Wave 0 |
| GATE-02 | Invalid API key → 401 without model call | unit | `pytest tests/test_auth.py::test_invalid_key` | Wave 0 |
| GATE-03 | RPM exceeded → 429 without model call | unit | `pytest tests/test_ratelimit.py::test_rpm_exceeded` | Wave 0 |
| GATE-03 | TPM exceeded → 429 on subsequent request | unit | `pytest tests/test_ratelimit.py::test_tpm_exceeded` | Wave 0 |
| GATE-04 | Request proxied to :4000, response forwarded | integration | `pytest tests/test_proxy.py::test_proxy_to_litellm` | Wave 0 |
| GATE-05 | bypass=true tenant skips guardrail stage, still logs trace | unit | `pytest tests/test_proxy.py::test_bypass_tenant` | Wave 0 |
| TRAC-01 | Each request writes a trace record with correct fields | unit | `pytest tests/test_traces.py::test_write_record` | Wave 0 |
| TRAC-02 | Guardrail/CAI fields are null when not set | unit | `pytest tests/test_traces.py::test_nullable_fields` | Wave 0 |
| TRAC-03 | PII in prompt/response is replaced with tokens before trace write | unit | `pytest tests/test_pii.py -x` | Wave 0 |
| TRAC-04 | query_by_id and query_by_timerange return correct records | unit | `pytest tests/test_traces.py::test_query` | Wave 0 |

### Sampling Rate

- **Per task commit:** `cd harness && python -m pytest tests/ -x -q`
- **Per wave merge:** `cd harness && python -m pytest tests/ -v`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps

- [ ] `harness/pyproject.toml` — pytest config, dependencies
- [ ] `harness/tests/__init__.py` — make tests a package
- [ ] `harness/tests/conftest.py` — AsyncClient fixture, temp SQLite db, mock tenants
- [ ] `harness/tests/test_auth.py` — GATE-02 tests
- [ ] `harness/tests/test_ratelimit.py` — GATE-03 tests
- [ ] `harness/tests/test_proxy.py` — GATE-01, GATE-04, GATE-05 tests
- [ ] `harness/tests/test_pii.py` — TRAC-03 tests
- [ ] `harness/tests/test_traces.py` — TRAC-01, TRAC-02, TRAC-04 tests
- [ ] `harness/tests/test_nemo_compat.py` — NeMo aarch64 go/no-go validation
- [ ] Framework install: `pip install pytest pytest-asyncio httpx` — not yet installed

---

## Sources

### Primary (HIGH confidence)

- [NeMo Guardrails Installation Guide](https://docs.nvidia.com/nemo/guardrails/latest/getting-started/installation-guide.html) — Python version support (3.10-3.13), Annoy C++ requirement
- [NeMo Guardrails GitHub Releases](https://github.com/NVIDIA-NeMo/Guardrails/releases) — v0.21.0 (2025-03-12) confirmed as latest
- [NeMo Guardrails Issue #137](https://github.com/NVIDIA/NeMo-Guardrails/issues/137) — LLMRails module-level init requirement confirmed
- [spaCy GitHub Issue #13622](https://github.com/explosion/spaCy/issues/13622) — aarch64 wheels confirmed available in 3.8.5+ (resolved May 2025)
- [FastAPI Lifespan Events](https://fastapi.tiangolo.com/advanced/events/) — lifespan pattern for httpx AsyncClient
- [FastAPI Async Tests](https://fastapi.tiangolo.com/advanced/async-tests/) — ASGITransport + pytest-asyncio pattern
- [argon2-cffi 25.1.0](https://argon2-cffi.readthedocs.io/) — Argon2id hash/verify API
- [aiosqlite docs](https://aiosqlite.omnilib.dev/) — async SQLite bridge
- [Microsoft Presidio Installation](https://microsoft.github.io/presidio/installation/) — presidio-analyzer + presidio-anonymizer
- [Annoy PyPI](https://pypi.org/project/annoy/) — 1.17.3 is latest; no aarch64 PyPI wheel confirmed

### Secondary (MEDIUM confidence)

- [spaCy Discussion #13728](https://github.com/explosion/spaCy/discussions/13728) — ARM64 blis failure root cause, confirmed fixed in 3.8.5+
- [deepwiki NeMo Guardrails Installation](https://deepwiki.com/NVIDIA/NeMo-Guardrails/1.1-installation-and-setup) — LLMRails architecture summary
- [argon2-cffi vs bcrypt comparison 2025](https://guptadeepak.com/the-complete-guide-to-password-hashing-argon2-vs-bcrypt-vs-scrypt-vs-pbkdf2-2026/) — Argon2id recommended over bcrypt

### Tertiary (LOW confidence — needs runtime validation)

- Annoy build from source on DGX Spark aarch64 success/failure — unverified, requires hardware test
- Presidio spaCy 3.8.5 compatibility — verified via spaCy universe listing Presidio; specific version matrix not confirmed in official docs
- LiteLLM :4000 availability and OpenAI-compatible response format — assumed from existing `start-litellm.sh` and `docker-compose.inference.yml`; must be running during integration tests

---

## Metadata

**Confidence breakdown:**

- Standard stack: HIGH — all library versions verified against official docs/PyPI/GitHub
- Architecture patterns: HIGH — FastAPI lifespan, httpx proxy, aiosqlite patterns all from official docs
- aarch64 build outcomes: LOW — theoretical analysis only; requires hardware validation (Wave 0 task)
- Pitfalls: MEDIUM-HIGH — Annoy and spaCy issues verified from official GitHub; LLMRails asyncio issue verified from issue tracker

**Research date:** 2026-03-22
**Valid until:** 2026-06-22 (stable ecosystem; spaCy/Presidio/FastAPI move slowly; NeMo Guardrails moves faster — recheck if planning beyond 90 days)
