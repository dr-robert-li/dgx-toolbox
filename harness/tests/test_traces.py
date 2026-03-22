"""Tests for TraceStore — covers TRAC-01, TRAC-02, TRAC-04."""
import pytest
import pytest_asyncio
from datetime import datetime, timezone


@pytest_asyncio.fixture
async def trace_store(tmp_path):
    """Create a fresh TraceStore in a temp directory."""
    from harness.traces.store import TraceStore
    db_path = str(tmp_path / "test_traces.db")
    store = TraceStore(db_path=db_path)
    await store.init_db()
    return store


def _make_record(request_id: str = "req-001", timestamp: str = None, **overrides):
    base = {
        "request_id": request_id,
        "tenant": "test-tenant",
        "timestamp": timestamp or datetime.now(timezone.utc).isoformat(),
        "model": "llama3.1",
        "prompt": "Hello",
        "response": "World",
        "latency_ms": 42,
        "status_code": 200,
        "guardrail_decisions": None,
        "cai_critique": None,
        "refusal_event": False,
        "bypass_flag": False,
    }
    base.update(overrides)
    return base


async def test_write_and_query_by_id(trace_store):
    """Write a record, query by request_id, get same record back."""
    record = _make_record("req-write-001")
    await trace_store.write(record)

    result = await trace_store.query_by_id("req-write-001")
    assert result is not None
    assert result["request_id"] == "req-write-001"
    assert result["tenant"] == "test-tenant"
    assert result["model"] == "llama3.1"
    assert result["prompt"] == "Hello"
    assert result["response"] == "World"
    assert result["latency_ms"] == 42
    assert result["status_code"] == 200


async def test_query_by_timerange(trace_store):
    """Write 3 records with different timestamps, query a range, get correct subset."""
    ts_early = "2025-01-01T10:00:00+00:00"
    ts_mid = "2025-01-01T12:00:00+00:00"
    ts_late = "2025-01-01T14:00:00+00:00"

    await trace_store.write(_make_record("req-range-001", timestamp=ts_early))
    await trace_store.write(_make_record("req-range-002", timestamp=ts_mid))
    await trace_store.write(_make_record("req-range-003", timestamp=ts_late))

    # Query mid to late (should return 2 records)
    results = await trace_store.query_by_timerange(since=ts_mid, until=ts_late)
    request_ids = [r["request_id"] for r in results]
    assert "req-range-002" in request_ids
    assert "req-range-003" in request_ids
    assert "req-range-001" not in request_ids


async def test_nullable_guardrail_fields(trace_store):
    """Write record with guardrail_decisions=None and cai_critique=None, verify they are null."""
    record = _make_record("req-null-001", guardrail_decisions=None, cai_critique=None)
    await trace_store.write(record)

    result = await trace_store.query_by_id("req-null-001")
    assert result is not None
    assert result["guardrail_decisions"] is None
    assert result["cai_critique"] is None


async def test_write_all_fields(trace_store):
    """Write record with all fields populated; verify round-trip."""
    record = _make_record(
        "req-full-001",
        guardrail_decisions={"blocked": False, "reason": None},
        cai_critique={"score": 0.9},
        refusal_event=True,
        bypass_flag=True,
    )
    await trace_store.write(record)

    result = await trace_store.query_by_id("req-full-001")
    assert result is not None
    # guardrail_decisions and cai_critique are stored as JSON strings
    import json
    gd = result["guardrail_decisions"]
    cc = result["cai_critique"]
    if isinstance(gd, str):
        gd = json.loads(gd)
    if isinstance(cc, str):
        cc = json.loads(cc)
    assert gd == {"blocked": False, "reason": None}
    assert cc == {"score": 0.9}
    # SQLite stores booleans as integers 0/1
    assert result["refusal_event"] in (1, True)
    assert result["bypass_flag"] in (1, True)


async def test_query_nonexistent_id(trace_store):
    """query_by_id for unknown ID returns None."""
    result = await trace_store.query_by_id("nonexistent-id-xyz")
    assert result is None
