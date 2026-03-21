# Stack Research

**Domain:** AI Safety Harness — FastAPI gateway with guardrails, evals, and red teaming on DGX Spark (aarch64)
**Researched:** 2026-03-22
**Confidence:** HIGH for core web framework and guardrails; MEDIUM for eval/red-teaming integrations

---

## Context: What Already Exists (Do Not Change)

The v1.0 modelstore layer is pure Bash on the host. The safety harness is the **first Python component** in this repo. It runs as a containerized service or virtualenv on top of the existing LiteLLM proxy.

| Existing Component | Role | Interface Point |
|-------------------|------|-----------------|
| LiteLLM proxy | Model routing (Ollama, vLLM, cloud) | Safety harness calls LiteLLM via OpenAI-compatible HTTP |
| Bash modelstore scripts | Tiered storage | No direct interface — storage is transparent via symlinks |
| DGX Spark aarch64 + NVIDIA GPU | Hardware | All Python deps must have aarch64 wheels or pure-Python fallback |

---

## Recommended Stack

### Core Framework

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| Python | 3.12 | Runtime | All target libraries support 3.10–3.13; 3.12 is the stable production choice with best wheel availability on aarch64 as of 2026. Avoid 3.13 until NeMo Guardrails explicitly lists it (current support: 3.10–3.13 per 0.21.0 docs). |
| FastAPI | 0.135.1 | HTTP gateway service — POST /chat and streaming endpoints | Industry-standard async framework for LLM gateways. Native async generator support for SSE streaming. Pydantic v2 built-in for request/response validation. Starlette's `StreamingResponse` pairs directly with NeMo Guardrails' async token generators. |
| uvicorn[standard] | latest | ASGI server (includes uvloop + httptools) | Required to run FastAPI. The `[standard]` extras install uvloop (faster event loop) and httptools (faster HTTP parsing) — both have aarch64 wheels. For production, run under gunicorn with uvicorn workers. |
| Pydantic | v2 (bundled with FastAPI) | Request/response models, config schemas | FastAPI has dropped Pydantic v1 support. Use Pydantic Settings for environment-based config (guardrail thresholds, judge model selection, etc.). |

### Safety and Guardrails Layer

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| nemoguardrails | 0.21.0 | Pre/post model content safety rails: prompt injection, jailbreak, PII, toxicity | NVIDIA's own toolkit, actively maintained (0.21.0 released March 2026). Native streaming support via `chunk_size` and sliding window buffer. Integrates via Python SDK (`LLMRails`, `RailsConfig`) directly inside the FastAPI request handler — no separate process needed for dev. Supports NVIDIA safety NIMs for production GPU-accelerated checks. Requires C++ compiler on aarch64 for the Annoy dependency — install `build-essential` first. |
| presidio-analyzer + presidio-anonymizer | 2.2.362 | PII detection and redaction in prompts and completions | Microsoft's production PII toolkit. The `analyzer` detects entities; `anonymizer` replaces them. Use as a NeMo Guardrails custom action or standalone pre-processing step. Supports spaCy models for NER — use `en_core_web_lg` for highest recall. The `[transformers]` extra enables transformer-based detection for edge cases. Pure Python — aarch64 compatible without compilation. |

### Constitutional AI Layer

NeMo Guardrails does not include a Constitutional AI (CAI) critique-revision loop out of the box. Implement directly via the LiteLLM-compatible call path — no additional library needed for the core loop.

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| httpx | 0.28.1 | Async HTTP client for calling LiteLLM proxy (judge model calls in CAI loop) | Fully async with connection pooling. Used to call LiteLLM's `/v1/chat/completions` for both the primary model and the judge model in the self-critique pass. Pairs cleanly with FastAPI's async request handlers. Do not use the `openai` Python SDK directly in the gateway — it adds unnecessary abstraction layers when LiteLLM proxy already normalizes the interface. |

### Authentication and Rate Limiting

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| PyJWT | 2.12.1 | JWT token generation and verification for per-tenant auth | FastAPI official docs now recommend PyJWT over python-jose (python-jose is effectively abandoned). Lightweight, actively maintained, aarch64-compatible pure Python. Use `pyjwt[crypto]` for RSA/ECDSA signature support. |
| slowapi | latest | Per-tenant rate limiting as FastAPI dependency | Built on limits library (Flask-Limiter port). Simpler integration than fastapi-limiter for use cases where the identifier is derived from JWT claims. Does not require Redis for single-node deployments — uses in-memory storage. Switch to fastapi-limiter + Redis when multi-worker or multi-process deployment is needed. |
| passlib[bcrypt] | latest | Password hashing for API key management | Standard FastAPI security recommendation. bcrypt is the preferred algorithm. |

### Trace Logging and Observability

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| structlog | 25.5.0 | Structured JSON logging of every request, guardrail decision, CAI critique, and eval result | Processes log events through a pipeline (timestamp → bound context → JSON renderer). Integrates with FastAPI via middleware that binds `request_id` and `tenant_id` to every log line downstream. Pure Python — no compilation needed. Better than stdlib logging for querying traces later. |
| SQLite + SQLModel | 0.0.37 | Persistent storage of full traces for replay eval harness | SQLModel (SQLAlchemy + Pydantic) is the natural companion to FastAPI (same author). Use SQLite for single-node DGX Spark — no separate database process, traces stored as structured rows. SQLModel's Pydantic integration means request/response models serialize directly into trace rows without adapter code. Upgrade to PostgreSQL if multi-node deployment is needed. |

### Eval Harness

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| lm-evaluation-harness (lm-eval) | 0.4.11 | General capability benchmarks (MMLU, HellaSwag, TruthfulQA, etc.) | EleutherAI's standard; used by Hugging Face Open LLM Leaderboard, NVIDIA, Cohere. Points at LiteLLM proxy via `--model openai-completions --model_args base_url=http://localhost:4000` — no special integration code. Install with `pip install lm-eval[vllm]` for GPU-accelerated local eval. Latest: v0.4.11 (Feb 2025). |
| pytest + httpx (async test client) | latest | Custom replay eval harness against POST /chat | pytest with `pytest-asyncio` lets you replay SQLite-stored traces against the live gateway and assert on guardrail decisions. Use FastAPI's `TestClient` or httpx `AsyncClient` with `ASGITransport` for in-process testing without network overhead. |
| pytest-asyncio | latest | Async test support for FastAPI endpoint testing | Required for `async def` test functions. Set `asyncio_mode = "auto"` in `pyproject.toml`. |

### Distributed Red Teaming

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| garak | 0.14.0 | LLM vulnerability scanner — 100+ attack modules | NVIDIA's own red teaming tool (pure Python, aarch64-compatible, Python >=3.10). Connects to LiteLLM proxy as an OpenAI-compatible endpoint. Run as a CLI scan (`garak --model openai --generator_option api_key=... --generator_option base_url=...`). Results feed back into the eval harness and guardrail threshold calibration. Latest: 0.14.0 (Feb 2026). |
| deepteam | 1.0.6 | Programmatic red teaming with 20+ attack types and 50+ vulnerability categories | Confident AI's framework — Python-native, importable, configurable via YAML or code. Better for live, feedback-loop red teaming than garak (which is more of a one-shot scanner). Use for the "distributed live red teaming from past critiques/evals/logs" feature — deepteam generates adversarial prompts based on past failure patterns. Python <3.14, >=3.9. |
| Celery | 5.6.2 | Distributed task queue for async red teaming jobs | Dispatches red teaming jobs across workers without blocking the gateway. Redis as broker (already used for rate limiting Redis backend). Pure Python — aarch64 compatible. Use for long-running garak scans and deepteam red teaming sessions that generate adversarial prompts from historical logs. |
| Redis | 7.x (system package) | Celery message broker + rate limiter backend | Already standard on Linux. `sudo apt install redis-server` or run in Docker. Single-node Redis is sufficient for this deployment. |

### Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| uv | Fast Python package/project manager | Replaces pip + venv. `uv venv` + `uv pip install` is significantly faster than pip for the large dependency tree (NeMo + presidio + lm-eval). Single binary, aarch64-compatible. |
| ruff | Python linting and formatting | Replaces flake8 + isort + black. Single tool, extremely fast. Configure in `pyproject.toml`. |
| mypy | Static type checking | FastAPI + Pydantic v2 are fully typed; mypy catches integration errors before runtime. |
| pre-commit | Git hooks for ruff + mypy | Prevents untyped or unlinted code from being committed. |
| pytest-cov | Test coverage reporting | Track guardrail and CAI logic coverage. |
| docker compose | Local service orchestration | Run FastAPI gateway + Redis + optional PostgreSQL together for development. Use for CI as well. |

---

## Installation

```bash
# Prerequisites: Python 3.12, build tools for NeMo Guardrails (Annoy C++ extension)
sudo apt install python3.12 python3.12-venv python3.12-dev build-essential redis-server

# Install uv (fast package manager)
curl -LsSf https://astral.sh/uv/install.sh | sh

# Create virtualenv and install core dependencies
uv venv .venv --python 3.12
source .venv/bin/activate

# Core gateway
uv pip install "fastapi[standard]" uvicorn[standard] pydantic-settings

# NeMo Guardrails (requires build-essential for Annoy)
uv pip install "nemoguardrails[server]"

# PII detection
uv pip install presidio-analyzer presidio-anonymizer spacy
python -m spacy download en_core_web_lg

# Auth + rate limiting
uv pip install "pyjwt[crypto]" slowapi "passlib[bcrypt]"

# Async HTTP client (CAI judge model calls)
uv pip install httpx

# Trace logging and storage
uv pip install structlog sqlmodel

# Eval harness
uv pip install "lm-eval[vllm]"
uv pip install pytest pytest-asyncio pytest-cov

# Red teaming
uv pip install garak deepteam
uv pip install "celery[redis]"

# Dev tools
uv pip install ruff mypy pre-commit
```

---

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| FastAPI | Flask, Django | Never for this use case — FastAPI's native async generators are essential for streaming guardrails. Flask is sync-first; Django adds too much ORM/template machinery. |
| FastAPI | LiteLLM as the gateway | LiteLLM handles model routing but has no first-class support for multi-step pipelines (guardrails → model → critique → trace). Build the safety harness as a separate service that calls LiteLLM, not as a LiteLLM plugin. |
| nemoguardrails | Guardrails AI (guardrails-hub) | Use Guardrails AI if you need structured output validation (JSON schemas, type enforcement) as your primary need. NeMo is better for conversational safety rails with dialog flow control and NVIDIA NIM integration. They are complementary, not mutually exclusive. |
| presidio-analyzer | GLiNER (via NeMo extras) | GLiNER is included as a NeMo Guardrails extra. Use presidio for production PII redaction (Microsoft-maintained, HIPAA-tested patterns). Use GLiNER when you need custom entity types that presidio doesn't cover. |
| httpx for CAI loop | openai Python SDK | openai SDK adds JWT/key management and retry logic not needed when calling LiteLLM proxy (which already handles auth and routing). httpx is leaner and gives full control over streaming. |
| slowapi (in-memory) | fastapi-limiter + Redis | Use fastapi-limiter when deploying with multiple uvicorn workers or multiple machines — Redis centralizes counters. slowapi in-memory is fine for single-worker dev and single-node production. |
| SQLite + SQLModel | PostgreSQL + SQLModel | Upgrade to PostgreSQL when traces exceed ~10GB or you need concurrent writes from multiple workers. SQLModel supports both backends transparently. |
| garak + deepteam | promptfoo | promptfoo is excellent for CI-integrated eval (YAML-driven), but its red teaming is less programmatic than deepteam. Use promptfoo if you want a UI for the eval results. |
| Celery + Redis | FastAPI BackgroundTasks | Use BackgroundTasks for lightweight async work (single request scope). Use Celery when red teaming jobs outlive request lifetime, need retry logic, or must run across multiple workers. |
| PyJWT | python-jose | python-jose has not been meaningfully updated since 2021 and has known security issues. PyJWT is now the FastAPI documentation recommendation. |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| python-jose | Effectively abandoned; FastAPI documentation explicitly moved away from it in 2024; compatibility issues on Python >=3.10 | PyJWT 2.12.1 |
| LangChain ConstitutionalChain | Heavyweight abstraction with unpredictable updates; LangChain's API surface changes frequently and adds significant dependency weight for a feature implementable in ~50 lines of async Python | Implement CAI critique-revision loop directly with httpx calls to LiteLLM |
| Synchronous requests library | Blocks the event loop in FastAPI's async context — kills streaming performance and concurrency under load | httpx with `AsyncClient` |
| Flask-based Guardrails API | NeMo Guardrails has a native FastAPI server mode — there is no reason to wrap it in a separate Flask process | nemoguardrails Python SDK called inline from FastAPI request handlers |
| OpenTelemetry full stack (Jaeger/Grafana) | Overkill for single-node DGX Spark. structlog + SQLite provides all the trace queryability needed without running a separate observability backend. | structlog + SQLite for structured trace storage; add OpenTelemetry later if multi-service deployment grows |
| Hugging Face `transformers` as the model serving layer inside the gateway | The gateway is a safety harness, not a model server. vLLM and Ollama (via LiteLLM) already handle model serving. Importing transformers into the gateway would bloat the process and create GPU memory conflicts. | Call LiteLLM proxy via httpx |
| `asyncio.run()` inside FastAPI route handlers | Calling `asyncio.run()` inside an already-running event loop raises RuntimeError. All async work must use `await` or `asyncio.create_task()`. | Native `async def` route handlers with `await` |

---

## Stack Patterns by Variant

**For streaming guardrails (every N tokens):**
- Use NeMo Guardrails' `chunk_size` config to set the token window
- Return `StreamingResponse(generator)` from FastAPI where `generator` is an `async def` with `yield`
- NeMo streaming uses a sliding window buffer (configurable `context_size`, default 50 tokens) — set `chunk_size` to match your latency tolerance
- Redact detected violations before yielding the chunk downstream

**For single-node development (no Redis):**
- slowapi in-memory rate limiting
- SQLite trace storage (single file, zero setup)
- Celery with `task_always_eager=True` for synchronous local execution
- Run uvicorn directly: `uvicorn app.main:app --reload`

**For production on DGX Spark (GPU-accelerated checks):**
- Install `nemoguardrails[nvidia]` to enable NVIDIA safety NIMs
- Use `nemoguardrails[server]` to run the guardrails engine as a separate actions server process (`nemoguardrails actions-server --port 8001`)
- Run FastAPI under gunicorn: `gunicorn app.main:app -w 4 -k uvicorn.workers.UvicornWorker`
- Redis for Celery broker and rate limiting

**For Constitutional AI self-critique pipeline:**
- Implement as a plain async function: `async def critique_and_revise(response, constitution, judge_model)` calling httpx to LiteLLM
- Constitution stored as YAML/TOML config file (user-editable)
- Judge model specified by name in config; default to same model as primary via LiteLLM routing
- First pass: ask judge to critique response against each constitutional principle
- Second pass: ask judge to revise response based on critiques
- Log both passes to SQLite traces

**For lm-eval-harness integration:**
- LiteLLM proxy already exposes `/v1/completions` and `/v1/chat/completions` — no custom adapter needed
- Point lm-eval at the proxy: `lm_eval --model openai-chat-completions --model_args model=<model_name>,base_url=http://localhost:4000,api_key=dummy`
- Run safety-specific custom tasks (stored in `evals/tasks/`) alongside standard benchmarks

---

## Version Compatibility

| Package | Compatible With | Notes |
|---------|-----------------|-------|
| nemoguardrails 0.21.0 | Python 3.10–3.13 | Requires build-essential for Annoy C++ extension on aarch64. Use `pip install "nemoguardrails[nvidia]"` for NVIDIA NIM support. |
| FastAPI 0.135.1 | Pydantic v2 only | Pydantic v1 support dropped. All models must use Pydantic v2 syntax. |
| SQLModel 0.0.37 | SQLAlchemy 2.0.x, Pydantic v2 | SQLModel 0.0.14+ supports Pydantic v2. Earlier versions do not — use >=0.0.14. |
| lm-eval 0.4.11 | Python 3.8+ | Install with `[vllm]` extra for GPU-accelerated local eval. Points at LiteLLM via OpenAI-compatible endpoint. |
| Celery 5.6.2 | Python >=3.9, Redis 6+ | Use `celery[redis]` extra. Redis 7.x recommended. |
| garak 0.14.0 | Python 3.10–3.12 | Python 3.13 not listed as supported. Pin to 3.12 runtime. |
| deepteam 1.0.6 | Python 3.9–3.13 | No architecture-specific wheels; pure Python — aarch64 compatible. |
| presidio-analyzer 2.2.362 | Python 3.10–3.13 | Requires spaCy model download after install (`python -m spacy download en_core_web_lg`). |
| PyJWT 2.12.1 | Python >=3.9 | Use `pyjwt[crypto]` for RSA/ECDSA. |

---

## Sources

- [nemoguardrails on PyPI](https://pypi.org/project/nemoguardrails/) — version 0.21.0, Python 3.10–3.13 (HIGH confidence, official registry)
- [NeMo Guardrails installation guide](https://docs.nvidia.com/nemo/guardrails/latest/getting-started/installation-guide.html) — C++ compiler requirement, extras (HIGH confidence, official docs)
- [NeMo Guardrails streaming docs](https://docs.nvidia.com/nemo/guardrails/latest/user-guides/advanced/streaming.html) — chunk_size, context_size, sliding window (HIGH confidence, official docs)
- [FastAPI on PyPI](https://pypi.org/project/fastapi/) — version 0.135.1 released March 1, 2026 (HIGH confidence, official registry)
- [lm-evaluation-harness releases](https://github.com/EleutherAI/lm-evaluation-harness/releases) — v0.4.11 released Feb 13, 2025 (HIGH confidence, official GitHub)
- [LiteLLM + lm-eval-harness tutorial](https://docs.litellm.ai/docs/tutorials/lm_evaluation_harness) — OpenAI-compatible endpoint integration (HIGH confidence, official docs)
- [garak on PyPI](https://pypi.org/project/garak/) — 0.14.0, Python 3.10–3.12, released Feb 2026 (HIGH confidence, official registry)
- [deepteam on PyPI](https://pypi.org/project/deepteam/) — 1.0.6, Python 3.9–3.13, released Mar 2026 (HIGH confidence, official registry)
- [presidio-analyzer on PyPI](https://pypi.org/project/presidio-analyzer/) — 2.2.362, Python 3.10–3.13 (HIGH confidence, official registry)
- [Celery on PyPI](https://pypi.org/project/celery/) — 5.6.2, Python >=3.9 (HIGH confidence, official registry)
- [PyJWT on PyPI](https://pypi.org/project/pyjwt/) — 2.12.1, Python >=3.9 (HIGH confidence, official registry)
- [structlog on PyPI](https://pypi.org/project/structlog/) — 25.5.0 (HIGH confidence, official registry)
- [SQLModel on PyPI](https://pypi.org/project/sqlmodel/) — 0.0.37, released Feb 21, 2026 (HIGH confidence, official registry)
- [httpx on PyPI](https://pypi.org/project/httpx/) — 0.28.1 (HIGH confidence, official registry)
- [FastAPI JWT discussion — python-jose deprecation](https://github.com/fastapi/fastapi/discussions/9587) — community confirmation of python-jose abandonment (MEDIUM confidence, community source but consistent with official docs)
- [NeMo Guardrails streaming blog — NVIDIA](https://developer.nvidia.com/blog/stream-smarter-and-safer-learn-how-nvidia-nemo-guardrails-enhance-llm-output-streaming/) — streaming implementation details (HIGH confidence, official NVIDIA blog)

---

*Stack research for: v1.1 Safety Harness — FastAPI gateway with NeMo Guardrails, CAI, evals, red teaming*
*Researched: 2026-03-22*
