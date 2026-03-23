"""Tests for red team data layer: schema extension, TraceStore job CRUD, near-miss query,
and dataset balance enforcement."""
from __future__ import annotations

import json
from pathlib import Path

import pytest
import pytest_asyncio

from harness.traces.store import TraceStore


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_store(tmp_path: Path) -> TraceStore:
    return TraceStore(db_path=str(tmp_path / "test.db"))


async def _init(store: TraceStore) -> None:
    await store.init_db()


# ---------------------------------------------------------------------------
# Task 1: redteam_jobs table and TraceStore CRUD
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_redteam_jobs_table_created(tmp_path):
    store = _make_store(tmp_path)
    await _init(store)
    import aiosqlite
    async with aiosqlite.connect(str(tmp_path / "test.db")) as db:
        async with db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='redteam_jobs'"
        ) as cur:
            row = await cur.fetchone()
    assert row is not None, "redteam_jobs table should exist after init_db()"


@pytest.mark.asyncio
async def test_create_and_get_job(tmp_path):
    store = _make_store(tmp_path)
    await _init(store)
    await store.create_job({"job_id": "rt-test1", "type": "garak"})
    job = await store.get_job("rt-test1")
    assert job is not None
    assert job["job_id"] == "rt-test1"
    assert job["status"] == "pending"
    assert job["type"] == "garak"


@pytest.mark.asyncio
async def test_update_job_status_running(tmp_path):
    store = _make_store(tmp_path)
    await _init(store)
    await store.create_job({"job_id": "rt-run1", "type": "garak"})
    await store.update_job_status("rt-run1", "running")
    job = await store.get_job("rt-run1")
    assert job["status"] == "running"


@pytest.mark.asyncio
async def test_update_job_status_complete(tmp_path):
    store = _make_store(tmp_path)
    await _init(store)
    await store.create_job({"job_id": "rt-done1", "type": "deepteam"})
    result_data = {"probes_run": 10, "failures": 0}
    await store.update_job_status("rt-done1", "complete", result=result_data)
    job = await store.get_job("rt-done1")
    assert job["status"] == "complete"
    assert job["completed_at"] is not None
    assert isinstance(job["result"], dict)
    assert job["result"]["probes_run"] == 10


@pytest.mark.asyncio
async def test_update_job_status_failed(tmp_path):
    store = _make_store(tmp_path)
    await _init(store)
    await store.create_job({"job_id": "rt-fail1", "type": "garak"})
    await store.update_job_status("rt-fail1", "failed", result={"error": "timeout"})
    job = await store.get_job("rt-fail1")
    assert job["status"] == "failed"
    assert job["result"]["error"] == "timeout"


@pytest.mark.asyncio
async def test_list_jobs(tmp_path):
    import asyncio
    store = _make_store(tmp_path)
    await _init(store)
    for i in range(3):
        await store.create_job({"job_id": f"rt-list{i}", "type": "garak"})
        await asyncio.sleep(0.01)  # ensure distinct timestamps
    jobs = await store.list_jobs(limit=2)
    assert len(jobs) == 2
    # Should be in created_at DESC order (most recent first)
    assert jobs[0]["job_id"] == "rt-list2"
    assert jobs[1]["job_id"] == "rt-list1"


@pytest.mark.asyncio
async def test_job_type_check_constraint(tmp_path):
    import aiosqlite
    store = _make_store(tmp_path)
    await _init(store)
    with pytest.raises(aiosqlite.IntegrityError):
        async with aiosqlite.connect(str(tmp_path / "test.db")) as db:
            await db.execute(
                "INSERT INTO redteam_jobs (job_id, type, status, created_at) VALUES (?,?,?,?)",
                ("bad-type", "invalid", "pending", "2026-01-01T00:00:00"),
            )
            await db.commit()


@pytest.mark.asyncio
async def test_job_status_check_constraint(tmp_path):
    import aiosqlite
    store = _make_store(tmp_path)
    await _init(store)
    with pytest.raises(aiosqlite.IntegrityError):
        async with aiosqlite.connect(str(tmp_path / "test.db")) as db:
            await db.execute(
                "INSERT INTO redteam_jobs (job_id, type, status, created_at) VALUES (?,?,?,?)",
                ("bad-status", "garak", "bogus", "2026-01-01T00:00:00"),
            )
            await db.commit()


@pytest.mark.asyncio
async def test_near_miss_query_returns_scored_traces(tmp_path):
    store = _make_store(tmp_path)
    await _init(store)
    guardrail_decisions = {
        "blocked": False,
        "refusal_mode": None,
        "triggering_rail": None,
        "all_results": [
            {"rail": "self_check_output", "result": "pass", "score": 0.6, "threshold": 0.8}
        ],
        "evasion_flags": [],
    }
    await store.write({
        "request_id": "near-miss-1",
        "tenant": "test",
        "timestamp": "2026-03-23T10:00:00",
        "model": "llama3",
        "prompt": "test prompt",
        "response": "test response",
        "latency_ms": 100,
        "status_code": 200,
        "guardrail_decisions": guardrail_decisions,
        "refusal_event": False,
        "bypass_flag": False,
    })
    results = await store.query_near_misses(since="2026-03-01T00:00:00")
    assert len(results) == 1
    assert results[0]["request_id"] == "near-miss-1"


@pytest.mark.asyncio
async def test_near_miss_query_excludes_blocked(tmp_path):
    store = _make_store(tmp_path)
    await _init(store)
    guardrail_decisions = {
        "blocked": True,
        "refusal_mode": "hard_block",
        "triggering_rail": "self_check_input",
        "all_results": [
            {"rail": "self_check_input", "result": "block", "score": 0.9, "threshold": 0.8}
        ],
        "evasion_flags": [],
    }
    await store.write({
        "request_id": "blocked-1",
        "tenant": "test",
        "timestamp": "2026-03-23T10:00:00",
        "model": "llama3",
        "prompt": "blocked prompt",
        "response": "blocked response",
        "latency_ms": 50,
        "status_code": 200,
        "guardrail_decisions": guardrail_decisions,
        "refusal_event": True,
        "bypass_flag": False,
    })
    results = await store.query_near_misses(since="2026-03-01T00:00:00")
    assert len(results) == 0, "Blocked traces should not appear in near-miss results"


@pytest.mark.asyncio
async def test_near_miss_query_excludes_clean(tmp_path):
    store = _make_store(tmp_path)
    await _init(store)
    guardrail_decisions = {
        "blocked": False,
        "refusal_mode": None,
        "triggering_rail": None,
        "all_results": [
            {"rail": "self_check_output", "result": "pass", "score": 0.0, "threshold": 0.8}
        ],
        "evasion_flags": [],
    }
    await store.write({
        "request_id": "clean-1",
        "tenant": "test",
        "timestamp": "2026-03-23T10:00:00",
        "model": "llama3",
        "prompt": "clean prompt",
        "response": "clean response",
        "latency_ms": 80,
        "status_code": 200,
        "guardrail_decisions": guardrail_decisions,
        "refusal_event": False,
        "bypass_flag": False,
    })
    results = await store.query_near_misses(since="2026-03-01T00:00:00")
    assert len(results) == 0, "Clean traces (all scores 0) should not appear in near-miss results"


@pytest.mark.asyncio
async def test_near_miss_query_respects_since(tmp_path):
    store = _make_store(tmp_path)
    await _init(store)
    guardrail_decisions = {
        "blocked": False,
        "refusal_mode": None,
        "triggering_rail": None,
        "all_results": [
            {"rail": "self_check_output", "result": "pass", "score": 0.7, "threshold": 0.8}
        ],
        "evasion_flags": [],
    }
    # Old trace (before since)
    await store.write({
        "request_id": "old-trace-1",
        "tenant": "test",
        "timestamp": "2026-02-01T00:00:00",
        "model": "llama3",
        "prompt": "old prompt",
        "response": "old response",
        "latency_ms": 90,
        "status_code": 200,
        "guardrail_decisions": guardrail_decisions,
        "refusal_event": False,
        "bypass_flag": False,
    })
    # New trace (after since)
    await store.write({
        "request_id": "new-trace-1",
        "tenant": "test",
        "timestamp": "2026-03-20T00:00:00",
        "model": "llama3",
        "prompt": "new prompt",
        "response": "new response",
        "latency_ms": 90,
        "status_code": 200,
        "guardrail_decisions": guardrail_decisions,
        "refusal_event": False,
        "bypass_flag": False,
    })
    results = await store.query_near_misses(since="2026-03-01T00:00:00")
    request_ids = [r["request_id"] for r in results]
    assert "new-trace-1" in request_ids
    assert "old-trace-1" not in request_ids


# ---------------------------------------------------------------------------
# Task 2: Dataset balance enforcement
# ---------------------------------------------------------------------------


def _write_jsonl(path: Path, entries: list[dict]) -> None:
    path.write_text("\n".join(json.dumps(e) for e in entries))


def test_balance_check_passes_within_ratio(tmp_path):
    from harness.redteam.balance import check_balance

    active_dir = tmp_path / "active"
    active_dir.mkdir()
    pending = tmp_path / "pending.jsonl"
    _write_jsonl(pending, [
        {"prompt": "a", "category": "injection", "expected_action": "block"},
        {"prompt": "b", "category": "injection", "expected_action": "block"},
        {"prompt": "c", "category": "violence", "expected_action": "block"},
        {"prompt": "d", "category": "violence", "expected_action": "block"},
    ])
    ok, violations = check_balance(pending, active_dir, max_category_ratio=0.60)
    assert ok is True
    assert violations == {}


def test_balance_check_rejects_over_ratio(tmp_path):
    from harness.redteam.balance import check_balance

    active_dir = tmp_path / "active"
    active_dir.mkdir()
    pending = tmp_path / "pending.jsonl"
    # 4 out of 5 are injection -> ratio=0.80, exceeds max_ratio=0.40
    _write_jsonl(pending, [
        {"prompt": "a", "category": "injection", "expected_action": "block"},
        {"prompt": "b", "category": "injection", "expected_action": "block"},
        {"prompt": "c", "category": "injection", "expected_action": "block"},
        {"prompt": "d", "category": "injection", "expected_action": "block"},
        {"prompt": "e", "category": "other", "expected_action": "block"},
    ])
    ok, violations = check_balance(pending, active_dir, max_category_ratio=0.40)
    assert ok is False
    assert "injection" in violations
    assert violations["injection"] == pytest.approx(0.8, abs=0.001)


def test_balance_check_combines_active_and_pending(tmp_path):
    from harness.redteam.balance import check_balance

    active_dir = tmp_path / "active"
    active_dir.mkdir()
    # 5 injection entries in active dataset
    active_file = active_dir / "safety-core.jsonl"
    _write_jsonl(active_file, [
        {"prompt": f"active-{i}", "category": "injection", "expected_action": "block"}
        for i in range(5)
    ])
    # pending: 5 injection + 15 other entries = 20 total entries added
    # combined: 10 injection out of 20 total = 50%, exceeds 0.40 cap
    pending = tmp_path / "pending.jsonl"
    pending_entries = [
        {"prompt": f"pending-inj-{i}", "category": "injection", "expected_action": "block"}
        for i in range(5)
    ] + [
        {"prompt": f"pending-other-{i}", "category": "other", "expected_action": "block"}
        for i in range(15)
    ]
    _write_jsonl(pending, pending_entries)
    ok, violations = check_balance(pending, active_dir, max_category_ratio=0.40)
    assert ok is False
    assert "injection" in violations


def test_balance_check_empty_pending(tmp_path):
    from harness.redteam.balance import check_balance

    active_dir = tmp_path / "active"
    active_dir.mkdir()
    pending = tmp_path / "pending.jsonl"
    pending.write_text("")
    ok, violations = check_balance(pending, active_dir, max_category_ratio=0.40)
    assert ok is True
    assert violations == {}


def test_balance_check_unknown_category(tmp_path):
    from harness.redteam.balance import check_balance

    active_dir = tmp_path / "active"
    active_dir.mkdir()
    pending = tmp_path / "pending.jsonl"
    # Entries without category field — should be counted as "unknown"
    _write_jsonl(pending, [
        {"prompt": "no-cat-1", "expected_action": "block"},
        {"prompt": "no-cat-2", "expected_action": "block"},
        {"prompt": "with-cat", "category": "injection", "expected_action": "block"},
    ])
    ok, violations = check_balance(pending, active_dir, max_category_ratio=0.40)
    # unknown=2/3=0.667 > 0.40 and injection=1/3=0.333 < 0.40
    assert ok is False
    assert "unknown" in violations
