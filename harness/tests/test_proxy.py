"""Tests for the proxy route — covers GATE-01, GATE-04, GATE-05, TRAC-01, TRAC-03."""
from __future__ import annotations

import asyncio
import json
from unittest.mock import AsyncMock, patch

import httpx
import pytest
import pytest_asyncio
from argon2 import PasswordHasher
from httpx import AsyncClient, ASGITransport, Response

from harness.config.loader import TenantConfig

_ph = PasswordHasher()

# ---------------------------------------------------------------------------
# Canned LiteLLM response
# ---------------------------------------------------------------------------
_LITELLM_RESPONSE = {
    "id": "chatcmpl-test",
    "object": "chat.completion",
    "choices": [
        {
            "index": 0,
            "message": {"role": "assistant", "content": "Hello back"},
            "finish_reason": "stop",
        }
    ],
    "usage": {"prompt_tokens": 5, "completion_tokens": 5, "total_tokens": 10},
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def test_tenants():
    return [
        TenantConfig(
            tenant_id="test-tenant",
            api_key_hash=_ph.hash("sk-test-key"),
            rpm_limit=60,
            tpm_limit=100000,
            allowed_models=["*"],
            bypass=False,
            pii_strictness="minimal",
        ),
        TenantConfig(
            tenant_id="bypass-tenant",
            api_key_hash=_ph.hash("sk-bypass-key"),
            rpm_limit=120,
            tpm_limit=500000,
            allowed_models=["*"],
            bypass=True,
            pii_strictness="minimal",
        ),
    ]


@pytest_asyncio.fixture
async def proxy_client(test_tenants, tmp_path):
    """AsyncClient backed by ASGI transport with mock LiteLLM and real TraceStore."""
    from harness.main import app
    from harness.ratelimit.sliding_window import SlidingWindowLimiter
    from harness.traces.store import TraceStore

    # Fresh rate limiter per test
    app.state.tenants = test_tenants
    app.state.rate_limiter = SlidingWindowLimiter()

    # Real TraceStore in a temp dir
    db_path = str(tmp_path / "test_traces.db")
    trace_store = TraceStore(db_path=db_path)
    await trace_store.init_db()
    app.state.trace_store = trace_store

    # Mock HTTP client that returns canned LiteLLM response
    mock_transport = httpx.MockTransport(
        lambda request: httpx.Response(200, json=_LITELLM_RESPONSE)
    )
    app.state.http_client = httpx.AsyncClient(
        base_url="http://mock-litellm",
        transport=mock_transport,
    )

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as ac:
        yield ac

    await app.state.http_client.aclose()


def _auth_headers(key: str = "sk-test-key") -> dict:
    return {"Authorization": f"Bearer {key}"}


def _chat_body(model: str = "llama3.1", content: str = "Hello") -> dict:
    return {
        "model": model,
        "messages": [{"role": "user", "content": content}],
    }


# ---------------------------------------------------------------------------
# GATE-01: Proxy returns model response
# ---------------------------------------------------------------------------

async def test_proxy_returns_model_response(proxy_client):
    """POST /v1/chat/completions returns LiteLLM response unchanged."""
    resp = await proxy_client.post(
        "/v1/chat/completions", json=_chat_body(), headers=_auth_headers()
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["choices"][0]["message"]["content"] == "Hello back"


# ---------------------------------------------------------------------------
# GATE-02: Auth enforcement
# ---------------------------------------------------------------------------

async def test_proxy_401_no_auth(proxy_client):
    """POST without Authorization header returns 403 (HTTPBearer) or 401."""
    resp = await proxy_client.post("/v1/chat/completions", json=_chat_body())
    assert resp.status_code in (401, 403)


async def test_proxy_401_bad_key(proxy_client):
    """POST with invalid Bearer token returns 401."""
    resp = await proxy_client.post(
        "/v1/chat/completions",
        json=_chat_body(),
        headers=_auth_headers("sk-wrong-key"),
    )
    assert resp.status_code == 401


# ---------------------------------------------------------------------------
# GATE-03: Rate limiting
# ---------------------------------------------------------------------------

async def test_proxy_429_rpm(proxy_client):
    """Exceed RPM limit, receive 429 with detail containing 'RPM'."""
    from harness.main import app

    # Set a very low RPM limit for the test tenant
    app.state.tenants[0] = TenantConfig(
        tenant_id="test-tenant",
        api_key_hash=app.state.tenants[0].api_key_hash,
        rpm_limit=1,
        tpm_limit=100000,
        allowed_models=["*"],
        bypass=False,
        pii_strictness="minimal",
    )

    # First request should succeed
    resp1 = await proxy_client.post(
        "/v1/chat/completions", json=_chat_body(), headers=_auth_headers()
    )
    assert resp1.status_code == 200

    # Second request should be rate limited
    resp2 = await proxy_client.post(
        "/v1/chat/completions", json=_chat_body(), headers=_auth_headers()
    )
    assert resp2.status_code == 429
    assert "RPM" in resp2.json().get("detail", "")


# ---------------------------------------------------------------------------
# TRAC-01: Trace written per request
# ---------------------------------------------------------------------------

async def test_proxy_writes_trace(proxy_client):
    """After successful request, trace record exists with correct fields."""
    from harness.main import app

    body = _chat_body(content="Testing trace write")
    resp = await proxy_client.post(
        "/v1/chat/completions", json=body, headers=_auth_headers()
    )
    assert resp.status_code == 200

    # BackgroundTask runs after response — give it a moment
    await asyncio.sleep(0.2)

    # Query trace store directly
    trace_store = app.state.trace_store
    records = await trace_store.query_by_timerange(since="2000-01-01T00:00:00")
    assert len(records) >= 1
    record = records[-1]
    assert record["tenant"] == "test-tenant"
    assert record["model"] == "llama3.1"
    assert record["status_code"] == 200
    assert record["latency_ms"] >= 0


# ---------------------------------------------------------------------------
# TRAC-03: PII redacted before trace write
# ---------------------------------------------------------------------------

async def test_proxy_pii_redacted_in_trace(proxy_client):
    """Prompt containing an email is stored with [EMAIL] in the trace."""
    from harness.main import app

    body = _chat_body(content="My email is john@example.com please help")
    resp = await proxy_client.post(
        "/v1/chat/completions", json=body, headers=_auth_headers()
    )
    assert resp.status_code == 200

    await asyncio.sleep(0.2)

    trace_store = app.state.trace_store
    records = await trace_store.query_by_timerange(since="2000-01-01T00:00:00")
    # Find the record with this prompt
    matching = [r for r in records if "[EMAIL]" in r["prompt"]]
    assert len(matching) >= 1, "No trace record with [EMAIL] found"
    assert "john@example.com" not in matching[-1]["prompt"]


# ---------------------------------------------------------------------------
# GATE-05: Bypass tenant
# ---------------------------------------------------------------------------

async def test_bypass_tenant_skips_guardrails(proxy_client):
    """Bypass tenant still gets proxied; trace has bypass_flag=1."""
    from harness.main import app

    resp = await proxy_client.post(
        "/v1/chat/completions",
        json=_chat_body(),
        headers=_auth_headers("sk-bypass-key"),
    )
    assert resp.status_code == 200
    assert resp.json()["choices"][0]["message"]["content"] == "Hello back"

    await asyncio.sleep(0.2)

    trace_store = app.state.trace_store
    records = await trace_store.query_by_timerange(since="2000-01-01T00:00:00")
    bypass_records = [r for r in records if r["bypass_flag"] in (1, True)]
    assert len(bypass_records) >= 1


async def test_bypass_tenant_still_authed(proxy_client):
    """Bypass tenant with wrong API key still gets 401."""
    resp = await proxy_client.post(
        "/v1/chat/completions",
        json=_chat_body(),
        headers=_auth_headers("sk-bypass-WRONG"),
    )
    assert resp.status_code == 401


# ---------------------------------------------------------------------------
# TRAC-01: Latency measured
# ---------------------------------------------------------------------------

async def test_trace_has_latency_ms(proxy_client):
    """Trace record has latency_ms >= 0."""
    from harness.main import app

    resp = await proxy_client.post(
        "/v1/chat/completions", json=_chat_body(), headers=_auth_headers()
    )
    assert resp.status_code == 200

    await asyncio.sleep(0.2)

    trace_store = app.state.trace_store
    records = await trace_store.query_by_timerange(since="2000-01-01T00:00:00")
    assert records, "No trace records found"
    assert records[-1]["latency_ms"] >= 0


# ---------------------------------------------------------------------------
# TRAC-02: Guardrail/CAI fields null in Phase 5
# ---------------------------------------------------------------------------

async def test_trace_guardrail_fields_null(proxy_client):
    """In Phase 5, guardrail_decisions and cai_critique are null in trace."""
    from harness.main import app

    resp = await proxy_client.post(
        "/v1/chat/completions", json=_chat_body(), headers=_auth_headers()
    )
    assert resp.status_code == 200

    await asyncio.sleep(0.2)

    trace_store = app.state.trace_store
    records = await trace_store.query_by_timerange(since="2000-01-01T00:00:00")
    assert records, "No trace records found"
    latest = records[-1]
    assert latest["guardrail_decisions"] is None
    assert latest["cai_critique"] is None
