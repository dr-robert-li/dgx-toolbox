"""Tests for HITL corrections: schema, TraceStore extensions, and FastAPI endpoints.

Covers HITL-01 (priority queue), HITL-02 (diff data extraction), HITL-04 (headless API).
"""
from __future__ import annotations

import json
from datetime import datetime, timezone

import pytest
import pytest_asyncio


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest_asyncio.fixture
async def store(tmp_path):
    """Create a fresh TraceStore with initialized schema in a temp directory."""
    from harness.traces.store import TraceStore

    db_path = str(tmp_path / "test_hitl.db")
    s = TraceStore(db_path=db_path)
    await s.init_db()
    return s


def _make_trace(
    request_id: str,
    *,
    tenant: str = "tenant-a",
    timestamp: str = "2026-01-01T12:00:00+00:00",
    guardrail_decisions: dict | None = None,
    cai_critique: dict | None = None,
) -> dict:
    """Helper to build a minimal trace record."""
    return {
        "request_id": request_id,
        "tenant": tenant,
        "timestamp": timestamp,
        "model": "llama3",
        "prompt": "Hello world",
        "response": "Hello",
        "latency_ms": 50,
        "status_code": 200,
        "guardrail_decisions": guardrail_decisions,
        "cai_critique": cai_critique,
        "refusal_event": False,
        "bypass_flag": False,
    }


def _gd(score: float, threshold: float = 0.8, rail: str = "pii") -> dict:
    """Build a guardrail_decisions dict with one rail result."""
    return {
        "blocked": score >= threshold,
        "all_results": [{"rail_name": rail, "score": score, "threshold": threshold}],
    }


# ---------------------------------------------------------------------------
# Task 1: Schema and TraceStore tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_schema_idempotent(tmp_path):
    """Calling init_db() twice on the same db does not raise; corrections table exists."""
    from harness.traces.store import TraceStore
    import aiosqlite

    db_path = str(tmp_path / "idempotent.db")
    s = TraceStore(db_path=db_path)
    await s.init_db()
    await s.init_db()  # Second call should not raise

    async with aiosqlite.connect(db_path) as db:
        async with db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='corrections'"
        ) as cursor:
            row = await cursor.fetchone()
    assert row is not None, "corrections table should exist after init_db()"

    # Verify columns
    async with aiosqlite.connect(db_path) as db:
        async with db.execute("PRAGMA table_info(corrections)") as cursor:
            cols = {row[1] for row in await cursor.fetchall()}
    expected_cols = {"id", "request_id", "reviewer", "action", "edited_response", "created_at", "trace_ref"}
    assert expected_cols.issubset(cols)


@pytest.mark.asyncio
async def test_write_correction_basic(store):
    """write_correction() inserts a row; query_corrections() returns it with matching fields."""
    correction = {
        "request_id": "req-001",
        "reviewer": "alice",
        "action": "approve",
        "edited_response": None,
        "trace_ref": None,
    }
    await store.write_correction(correction)

    results = await store.query_corrections(request_id="req-001")
    assert len(results) == 1
    row = results[0]
    assert row["request_id"] == "req-001"
    assert row["reviewer"] == "alice"
    assert row["action"] == "approve"
    assert row["edited_response"] is None
    assert "created_at" in row


@pytest.mark.asyncio
async def test_write_correction_pii_redacted(store):
    """write_correction() with edited_response containing email stores a redacted version."""
    correction = {
        "request_id": "req-pii",
        "reviewer": "bob",
        "action": "edit",
        "edited_response": "Please contact john@example.com for support",
        "trace_ref": None,
    }
    await store.write_correction(correction)

    results = await store.query_corrections(request_id="req-pii")
    assert len(results) == 1
    stored = results[0]["edited_response"]
    assert stored is not None
    assert "john@example.com" not in stored, "Raw email should not be stored"
    assert "[EMAIL]" in stored or "[REDACTED]" in stored or "@" not in stored


@pytest.mark.asyncio
async def test_write_correction_action_constraint(store):
    """action must be one of approve/reject/edit; invalid action raises."""
    correction = {
        "request_id": "req-bad",
        "reviewer": "eve",
        "action": "invalid_action",
        "edited_response": None,
        "trace_ref": None,
    }
    with pytest.raises(Exception):
        await store.write_correction(correction)


@pytest.mark.asyncio
async def test_queue_priority_sort(store):
    """Insert 3 traces with different distances from threshold; queue sorted closest-to-threshold first."""
    # score=0.79 -> distance=0.01 -> priority=0.99 (highest)
    await store.write(_make_trace("req-close", guardrail_decisions=_gd(0.79)))
    # score=0.50 -> distance=0.30 -> priority=0.70 (middle)
    await store.write(_make_trace("req-mid", guardrail_decisions=_gd(0.50)))
    # score=0.10 -> distance=0.70 -> priority=0.30 (lowest)
    await store.write(_make_trace("req-far", guardrail_decisions=_gd(0.10)))

    since = "2026-01-01T00:00:00+00:00"
    results = await store.query_hitl_queue(since=since)

    request_ids = [r["request_id"] for r in results]
    assert request_ids.index("req-close") < request_ids.index("req-mid")
    assert request_ids.index("req-mid") < request_ids.index("req-far")


@pytest.mark.asyncio
async def test_queue_reviewed_items_last(store):
    """Insert traces, add correction for one; query puts reviewed item after unreviewed."""
    await store.write(_make_trace("req-unreviewed", guardrail_decisions=_gd(0.79)))
    await store.write(_make_trace("req-reviewed", guardrail_decisions=_gd(0.78)))

    await store.write_correction({
        "request_id": "req-reviewed",
        "reviewer": "alice",
        "action": "approve",
        "edited_response": None,
        "trace_ref": None,
    })

    since = "2026-01-01T00:00:00+00:00"
    results = await store.query_hitl_queue(since=since)
    request_ids = [r["request_id"] for r in results]
    assert request_ids.index("req-unreviewed") < request_ids.index("req-reviewed")


@pytest.mark.asyncio
async def test_queue_hide_reviewed(store):
    """With hide_reviewed=True, reviewed items are excluded from results."""
    await store.write(_make_trace("req-unreviewed2", guardrail_decisions=_gd(0.79)))
    await store.write(_make_trace("req-reviewed2", guardrail_decisions=_gd(0.78)))

    await store.write_correction({
        "request_id": "req-reviewed2",
        "reviewer": "alice",
        "action": "approve",
        "edited_response": None,
        "trace_ref": None,
    })

    since = "2026-01-01T00:00:00+00:00"
    results = await store.query_hitl_queue(since=since, hide_reviewed=True)
    request_ids = [r["request_id"] for r in results]
    assert "req-unreviewed2" in request_ids
    assert "req-reviewed2" not in request_ids


@pytest.mark.asyncio
async def test_queue_rail_filter(store):
    """With rail_filter='pii', only traces where triggering rail is 'pii' are returned."""
    await store.write(_make_trace(
        "req-pii-trace",
        guardrail_decisions=_gd(0.79, rail="pii"),
    ))
    await store.write(_make_trace(
        "req-violence-trace",
        guardrail_decisions=_gd(0.79, rail="violence"),
    ))

    since = "2026-01-01T00:00:00+00:00"
    results = await store.query_hitl_queue(since=since, rail_filter="pii")
    request_ids = [r["request_id"] for r in results]
    assert "req-pii-trace" in request_ids
    assert "req-violence-trace" not in request_ids


@pytest.mark.asyncio
async def test_queue_tenant_filter(store):
    """With tenant_filter='tenant-a', only traces from that tenant are returned."""
    await store.write(_make_trace("req-tenant-a", tenant="tenant-a", guardrail_decisions=_gd(0.79)))
    await store.write(_make_trace("req-tenant-b", tenant="tenant-b", guardrail_decisions=_gd(0.79)))

    since = "2026-01-01T00:00:00+00:00"
    results = await store.query_hitl_queue(since=since, tenant_filter="tenant-a")
    request_ids = [r["request_id"] for r in results]
    assert "req-tenant-a" in request_ids
    assert "req-tenant-b" not in request_ids


@pytest.mark.asyncio
async def test_queue_time_filter(store):
    """Only traces within the since window are returned."""
    await store.write(_make_trace(
        "req-old", timestamp="2025-01-01T00:00:00+00:00", guardrail_decisions=_gd(0.79)
    ))
    await store.write(_make_trace(
        "req-new", timestamp="2026-06-01T00:00:00+00:00", guardrail_decisions=_gd(0.79)
    ))

    since = "2026-01-01T00:00:00+00:00"
    results = await store.query_hitl_queue(since=since)
    request_ids = [r["request_id"] for r in results]
    assert "req-new" in request_ids
    assert "req-old" not in request_ids


@pytest.mark.asyncio
async def test_queue_no_all_results(store):
    """Traces with guardrail_decisions lacking all_results get priority=0 (graceful fallback)."""
    await store.write(_make_trace(
        "req-no-results",
        guardrail_decisions={"blocked": False},
    ))

    since = "2026-01-01T00:00:00+00:00"
    results = await store.query_hitl_queue(since=since)
    matches = [r for r in results if r["request_id"] == "req-no-results"]
    assert len(matches) == 1
    assert matches[0]["priority"] == 0.0


@pytest.mark.asyncio
async def test_diff_extraction(store):
    """For traces with cai_critique, original_output and revised_output accessible in queue result."""
    cai = {
        "original_output": "original response text",
        "revised_output": "revised response text",
        "critique": "This needs revision",
    }
    await store.write(_make_trace(
        "req-cai",
        guardrail_decisions=_gd(0.79),
        cai_critique=cai,
    ))
    await store.write(_make_trace(
        "req-no-cai",
        guardrail_decisions=_gd(0.79),
        cai_critique=None,
    ))

    since = "2026-01-01T00:00:00+00:00"
    results = await store.query_hitl_queue(since=since)

    cai_result = next(r for r in results if r["request_id"] == "req-cai")
    no_cai_result = next(r for r in results if r["request_id"] == "req-no-cai")

    assert cai_result["cai_critique"] is not None
    assert isinstance(cai_result["cai_critique"], dict)
    assert cai_result["cai_critique"]["original_output"] == "original response text"
    assert cai_result["cai_critique"]["revised_output"] == "revised response text"
    assert no_cai_result["cai_critique"] is None


# ---------------------------------------------------------------------------
# Task 2: FastAPI endpoint tests
# ---------------------------------------------------------------------------


def _make_hitl_app(tmp_path):
    """Create a minimal FastAPI test app with HITL router and mocked state."""
    import asyncio
    from fastapi import FastAPI
    from harness.hitl.router import hitl_router
    from harness.auth.bearer import verify_api_key
    from harness.config.loader import TenantConfig
    from harness.traces.store import TraceStore

    app = FastAPI()
    app.include_router(hitl_router)

    async def fake_verify_api_key():
        return TenantConfig(
            tenant_id="test",
            api_key_hash="$argon2id$v=19$m=65536,t=3,p=4$fakehash",
            bypass=True,
        )

    app.dependency_overrides[verify_api_key] = fake_verify_api_key

    db_path = str(tmp_path / "test_hitl_router.db")
    trace_store = TraceStore(db_path=db_path)
    app.state.trace_store = trace_store

    return app, trace_store


@pytest.mark.asyncio
async def test_queue_endpoint_auth(tmp_path):
    """GET /admin/hitl/queue without auth returns 401; with valid API key returns 200."""
    from harness.traces.store import TraceStore
    from harness.hitl.router import hitl_router
    from fastapi import FastAPI
    from httpx import ASGITransport, AsyncClient

    # App without dependency override (real auth)
    raw_app = FastAPI()
    raw_app.include_router(hitl_router)
    db_path = str(tmp_path / "auth_test.db")
    ts = TraceStore(db_path=db_path)
    await ts.init_db()
    raw_app.state.trace_store = ts

    async with AsyncClient(transport=ASGITransport(app=raw_app), base_url="http://test") as client:
        resp = await client.get("/admin/hitl/queue")
    assert resp.status_code in (401, 403), f"Expected 401/403 without auth, got {resp.status_code}"

    # App with auth override
    app, store = _make_hitl_app(tmp_path)
    await store.init_db()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        resp = await client.get(
            "/admin/hitl/queue",
            headers={"Authorization": "Bearer test-key"},
        )
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_queue_endpoint_filters(tmp_path):
    """GET /admin/hitl/queue?rail=pii&since=1h&hide_reviewed=true passes params correctly."""
    from httpx import ASGITransport, AsyncClient
    from unittest.mock import AsyncMock, patch

    app, store = _make_hitl_app(tmp_path)
    await store.init_db()

    with patch.object(store, "query_hitl_queue", new=AsyncMock(return_value=[])) as mock_query:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            resp = await client.get(
                "/admin/hitl/queue?rail=pii&since=1h&hide_reviewed=true",
                headers={"Authorization": "Bearer test-key"},
            )

    assert resp.status_code == 200
    mock_query.assert_called_once()
    call_kwargs = mock_query.call_args.kwargs
    assert call_kwargs.get("rail_filter") == "pii"
    assert call_kwargs.get("hide_reviewed") is True


@pytest.mark.asyncio
async def test_correct_endpoint(tmp_path):
    """POST /admin/hitl/correct with approve action returns 200 and correction is written."""
    from httpx import ASGITransport, AsyncClient

    app, store = _make_hitl_app(tmp_path)
    await store.init_db()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        resp = await client.post(
            "/admin/hitl/correct",
            json={
                "request_id": "req-approve",
                "reviewer": "alice",
                "action": "approve",
            },
            headers={"Authorization": "Bearer test-key"},
        )

    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ok"
    assert data["request_id"] == "req-approve"

    corrections = await store.query_corrections(request_id="req-approve")
    assert len(corrections) == 1
    assert corrections[0]["action"] == "approve"


@pytest.mark.asyncio
async def test_correct_endpoint_edit(tmp_path):
    """POST /admin/hitl/correct with action 'edit' and edited_response returns 200."""
    from httpx import ASGITransport, AsyncClient

    app, store = _make_hitl_app(tmp_path)
    await store.init_db()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        resp = await client.post(
            "/admin/hitl/correct",
            json={
                "request_id": "req-edit",
                "reviewer": "bob",
                "action": "edit",
                "edited_response": "This is the corrected response",
            },
            headers={"Authorization": "Bearer test-key"},
        )

    assert resp.status_code == 200
    corrections = await store.query_corrections(request_id="req-edit")
    assert len(corrections) == 1
    assert corrections[0]["action"] == "edit"


@pytest.mark.asyncio
async def test_correct_endpoint_invalid_action(tmp_path):
    """POST /admin/hitl/correct with action 'invalid' returns 422."""
    from httpx import ASGITransport, AsyncClient

    app, store = _make_hitl_app(tmp_path)
    await store.init_db()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        resp = await client.post(
            "/admin/hitl/correct",
            json={
                "request_id": "req-bad",
                "reviewer": "alice",
                "action": "invalid_action",
            },
            headers={"Authorization": "Bearer test-key"},
        )

    assert resp.status_code == 422


@pytest.mark.asyncio
async def test_headless_api_mode(tmp_path):
    """App starts without gradio installed; queue endpoint returns data."""
    import sys
    from httpx import ASGITransport, AsyncClient

    app, store = _make_hitl_app(tmp_path)
    await store.init_db()

    # Simulate gradio not installed
    gradio_module = sys.modules.pop("gradio", None)
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            resp = await client.get(
                "/admin/hitl/queue",
                headers={"Authorization": "Bearer test-key"},
            )
        assert resp.status_code == 200
        data = resp.json()
        assert "queue" in data
        assert "count" in data
    finally:
        if gradio_module is not None:
            sys.modules["gradio"] = gradio_module


@pytest.mark.asyncio
async def test_queue_response_shape(tmp_path):
    """Queue response contains required fields for each item."""
    from httpx import ASGITransport, AsyncClient

    app, store = _make_hitl_app(tmp_path)
    await store.init_db()

    await store.write(_make_trace(
        "req-shape",
        guardrail_decisions=_gd(0.79),
        cai_critique={"original_output": "orig", "revised_output": "rev"},
    ))

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        resp = await client.get(
            "/admin/hitl/queue?since=2026-01-01T00:00:00+00:00",
            headers={"Authorization": "Bearer test-key"},
        )

    assert resp.status_code == 200
    data = resp.json()
    assert data["count"] >= 1
    item = data["queue"][0]
    required_fields = {"request_id", "timestamp", "tenant", "priority", "correction_action", "guardrail_decisions", "cai_critique"}
    for field in required_fields:
        assert field in item, f"Missing field: {field}"
