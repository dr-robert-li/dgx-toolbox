"""Tests for TraceStore eval_runs extension — covers write_eval_run and query_eval_runs."""
import pytest
import pytest_asyncio
from datetime import datetime, timezone


@pytest_asyncio.fixture
async def eval_store(tmp_path):
    """Create a fresh TraceStore in a temp directory with DB initialized."""
    from harness.traces.store import TraceStore
    db_path = str(tmp_path / "test_eval.db")
    store = TraceStore(db_path=db_path)
    await store.init_db()
    return store


def _make_eval_run(
    run_id: str = "replay-abc123",
    source: str = "replay",
    timestamp: str = None,
    **overrides,
) -> dict:
    base = {
        "run_id": run_id,
        "timestamp": timestamp or datetime.now(timezone.utc).isoformat(),
        "source": source,
        "metrics": {"f1": 0.85, "precision": 0.9, "recall": 0.8},
        "config_snapshot": {"model": "llama3.1", "dataset": "safety-core.jsonl"},
        "baseline_name": None,
    }
    base.update(overrides)
    return base


async def test_write_and_query(eval_store):
    """Write one eval_run record, query it back, verify all fields match."""
    record = _make_eval_run(
        run_id="replay-test001",
        source="replay",
        metrics={"f1": 0.9, "precision": 0.95, "recall": 0.85},
        config_snapshot={"model": "llama3.1", "dataset": "safety-core.jsonl"},
    )
    await eval_store.write_eval_run(record)

    results = await eval_store.query_eval_runs()
    assert len(results) == 1
    result = results[0]
    assert result["run_id"] == "replay-test001"
    assert result["source"] == "replay"
    assert result["metrics"]["f1"] == 0.9
    assert result["config_snapshot"]["model"] == "llama3.1"


async def test_query_filter_by_source(eval_store):
    """Write replay and lm-eval records; query with source='replay' returns only 1."""
    await eval_store.write_eval_run(_make_eval_run(run_id="replay-001", source="replay"))
    await eval_store.write_eval_run(_make_eval_run(run_id="lmeval-001", source="lm-eval"))

    replay_results = await eval_store.query_eval_runs(source="replay")
    assert len(replay_results) == 1
    assert replay_results[0]["run_id"] == "replay-001"

    lmeval_results = await eval_store.query_eval_runs(source="lm-eval")
    assert len(lmeval_results) == 1
    assert lmeval_results[0]["run_id"] == "lmeval-001"


async def test_query_limit(eval_store):
    """Write 10 records; query with limit=5 returns 5 records in DESC timestamp order."""
    from datetime import timedelta

    base_time = datetime(2026, 1, 1, 0, 0, 0, tzinfo=timezone.utc)
    for i in range(10):
        ts = (base_time + timedelta(hours=i)).isoformat()
        await eval_store.write_eval_run(
            _make_eval_run(run_id=f"replay-{i:03d}", timestamp=ts)
        )

    results = await eval_store.query_eval_runs(limit=5)
    assert len(results) == 5
    # Should be ordered by timestamp DESC — most recent first
    timestamps = [r["timestamp"] for r in results]
    assert timestamps == sorted(timestamps, reverse=True)
