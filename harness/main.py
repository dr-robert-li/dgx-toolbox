"""DGX Safety Harness — FastAPI app factory with lifespan."""
from __future__ import annotations

import os
from contextlib import asynccontextmanager
from typing import Annotated

import httpx
from fastapi import Depends, FastAPI

from harness.auth.bearer import verify_api_key
from harness.config.loader import TenantConfig, load_tenants
from harness.ratelimit.sliding_window import SlidingWindowLimiter
from harness.traces.store import TraceStore

# Config path: prefer env var, default to harness/config relative to cwd
_CONFIG_DIR = os.environ.get("HARNESS_CONFIG_DIR", os.path.join(os.path.dirname(__file__), "config"))
_LITELLM_BASE = os.environ.get("LITELLM_BASE_URL", "http://localhost:4000")
_DATA_DIR = os.environ.get("HARNESS_DATA_DIR", os.path.join(os.path.dirname(__file__), "data"))


@asynccontextmanager
async def lifespan(app: FastAPI):
    """App lifespan: load tenants, create HTTP client pool, initialize rate limiter and trace store."""
    # Load tenant config
    tenants_path = os.path.join(_CONFIG_DIR, "tenants.yaml")
    app.state.tenants = load_tenants(tenants_path)

    # Shared async HTTP client for proxying to LiteLLM
    app.state.http_client = httpx.AsyncClient(
        base_url=_LITELLM_BASE,
        timeout=httpx.Timeout(120.0),
        limits=httpx.Limits(max_connections=50, max_keepalive_connections=20),
    )

    # In-memory rate limiter (per-tenant RPM + TPM)
    app.state.rate_limiter = SlidingWindowLimiter()

    # Trace store — initialize SQLite schema (WAL mode, indexes)
    os.makedirs(_DATA_DIR, exist_ok=True)
    db_path = os.path.join(_DATA_DIR, "traces.db")
    app.state.trace_store = TraceStore(db_path=db_path)
    await app.state.trace_store.init_db()

    # Eagerly import PII redactor so AnalyzerEngine loads at startup
    import harness.pii.redactor  # noqa: F401

    # Initialize guardrail engine (NeMo init happens inside create_guardrail_engine)
    from harness.guards.engine import create_guardrail_engine
    rails_config_path = os.path.join(_CONFIG_DIR, "rails", "rails.yaml")
    nemo_config_dir = os.path.join(_CONFIG_DIR, "rails")
    app.state.guardrail_engine = create_guardrail_engine(
        rails_config_path=rails_config_path,
        nemo_config_dir=nemo_config_dir,
        litellm_base_url=_LITELLM_BASE,
    )

    yield

    await app.state.http_client.aclose()


app = FastAPI(
    title="DGX Safety Harness",
    description="FastAPI gateway with auth, rate limiting, PII-safe tracing, and guardrails.",
    version="0.1.0",
    lifespan=lifespan,
)

# Register proxy route
from harness.proxy.litellm import router  # noqa: E402
app.include_router(router)


@app.post("/probe")
async def probe(tenant: Annotated[TenantConfig, Depends(verify_api_key)]):
    """Probe endpoint used in tests to verify auth resolves to the correct tenant."""
    return {"tenant_id": tenant.tenant_id, "bypass": tenant.bypass}
