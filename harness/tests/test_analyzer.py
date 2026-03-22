"""Tests for analyze_traces() — CSTL-05 tuning analysis system.

Tests cover:
- Normal analysis with sufficient trace data
- Empty trace history (no cai_critique records)
- Below-minimum trace count
- yaml_diffs structure validation
- Pattern aggregation
- Graceful handling of judge model JSON parse failures
"""
from __future__ import annotations

import json
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

import pytest
import pytest_asyncio


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_constitution():
    """Build a minimal ConstitutionConfig for testing."""
    from harness.critique.constitution import ConstitutionConfig, Principle

    return ConstitutionConfig(
        judge_model="test-judge",
        principles=[
            Principle(
                id="P-SAFETY-01",
                text="Do not instruct harm.",
                category="safety",
                priority=1.0,
                enabled=True,
            ),
            Principle(
                id="P-FAIRNESS-01",
                text="Treat groups equitably.",
                category="fairness",
                priority=0.85,
                enabled=True,
            ),
        ],
    )


def _make_cai_critique(
    triggered_by: str = "self_check_output",
    outcome: str = "revised",
    violated: list[str] | None = None,
    original_score: float = 0.65,
    confidence: float = 0.87,
) -> dict:
    return {
        "triggered_by": triggered_by,
        "judge_model": "llama3.1",
        "original_score": original_score,
        "critique_threshold": 0.5,
        "judge_response": {
            "violated_principles": violated or ["P-SAFETY-01"],
            "critique": "The response contains harmful content.",
            "revision": "Here is a safer response.",
            "confidence": confidence,
        },
        "revision_score": 0.3,
        "outcome": outcome,
    }


async def _write_n_traces(store, n: int, with_critique: bool = True, since_delta_s: int = 3600):
    """Write n trace records to the store, optionally with cai_critique."""
    base_ts = datetime.now(timezone.utc) - timedelta(seconds=since_delta_s)
    for i in range(n):
        ts = (base_ts + timedelta(seconds=i)).isoformat()
        await store.write(
            {
                "request_id": str(uuid.uuid4()),
                "tenant": "test-tenant",
                "timestamp": ts,
                "model": "llama3.1",
                "prompt": "Hello",
                "response": "World",
                "latency_ms": 100,
                "status_code": 200,
                "guardrail_decisions": None,
                "cai_critique": _make_cai_critique() if with_critique else None,
                "refusal_event": False,
                "bypass_flag": False,
            }
        )


def _make_http_client_mock(suggestions=None, summary="Test summary"):
    """Return an AsyncMock http_client that returns a well-formed judge response."""
    if suggestions is None:
        suggestions = [
            {
                "type": "threshold",
                "rail": "self_check_output",
                "current": 0.5,
                "suggested": 0.6,
                "reason": "High trigger rate suggests threshold too low.",
            },
            {
                "type": "principle",
                "action": "disable",
                "id": "P-FAIRNESS-01",
                "reason": "Never violated in 30 days.",
            },
        ]
    response_json = {"suggestions": suggestions, "summary": summary}
    mock_response = MagicMock()
    mock_response.json.return_value = {
        "choices": [
            {
                "message": {
                    "content": json.dumps(response_json),
                }
            }
        ]
    }
    http_client = MagicMock()
    http_client.post = AsyncMock(return_value=mock_response)
    return http_client


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest_asyncio.fixture
async def store(tmp_path):
    from harness.traces.store import TraceStore

    db_path = str(tmp_path / "traces.db")
    s = TraceStore(db_path=db_path)
    await s.init_db()
    return s


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_analyze_traces_returns_report(store):
    """15 traces with cai_critique → returns dict with report, yaml_diffs, generated_at."""
    from harness.critique.analyzer import analyze_traces

    await _write_n_traces(store, 15, with_critique=True)

    since = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()
    http_client = _make_http_client_mock()
    constitution = _make_constitution()

    result = await analyze_traces(
        trace_store=store,
        http_client=http_client,
        constitution=constitution,
        since=since,
    )

    assert isinstance(result, dict)
    assert "report" in result
    assert "yaml_diffs" in result
    assert "generated_at" in result
    assert "## Tuning Suggestions" in result["report"]
    assert isinstance(result["yaml_diffs"], list)
    # generated_at should be parseable ISO8601
    datetime.fromisoformat(result["generated_at"])


@pytest.mark.asyncio
async def test_analyze_empty_traces(store):
    """0 traces with cai_critique → returns empty result without calling judge."""
    from harness.critique.analyzer import analyze_traces

    # Write traces but ALL with cai_critique=None
    await _write_n_traces(store, 5, with_critique=False)

    since = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()
    http_client = _make_http_client_mock()
    constitution = _make_constitution()

    result = await analyze_traces(
        trace_store=store,
        http_client=http_client,
        constitution=constitution,
        since=since,
    )

    assert "Insufficient data" in result["report"]
    assert result["yaml_diffs"] == []
    assert "generated_at" in result
    # http_client.post must NOT be called
    http_client.post.assert_not_called()


@pytest.mark.asyncio
async def test_analyze_below_minimum(store):
    """5 traces with cai_critique (below MIN_SAMPLE_SIZE=10) → no judge call."""
    from harness.critique.analyzer import analyze_traces

    await _write_n_traces(store, 5, with_critique=True)

    since = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()
    http_client = _make_http_client_mock()
    constitution = _make_constitution()

    result = await analyze_traces(
        trace_store=store,
        http_client=http_client,
        constitution=constitution,
        since=since,
    )

    assert "Insufficient data" in result["report"]
    assert result["yaml_diffs"] == []
    http_client.post.assert_not_called()


@pytest.mark.asyncio
async def test_yaml_diffs_structure(store):
    """Each yaml_diffs entry has 'type' key; threshold entries have rail/current/suggested;
    principle entries have action/id/reason."""
    from harness.critique.analyzer import analyze_traces

    await _write_n_traces(store, 15, with_critique=True)

    suggestions = [
        {
            "type": "threshold",
            "rail": "self_check_output",
            "current": 0.5,
            "suggested": 0.65,
            "reason": "Frequent triggers.",
        },
        {
            "type": "principle",
            "action": "enable",
            "id": "P-NEW-01",
            "reason": "Emerging risk pattern.",
        },
    ]
    http_client = _make_http_client_mock(suggestions=suggestions)
    constitution = _make_constitution()
    since = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()

    result = await analyze_traces(
        trace_store=store,
        http_client=http_client,
        constitution=constitution,
        since=since,
    )

    assert len(result["yaml_diffs"]) == 2

    threshold_diffs = [d for d in result["yaml_diffs"] if d["type"] == "threshold"]
    principle_diffs = [d for d in result["yaml_diffs"] if d["type"] == "principle"]

    assert len(threshold_diffs) == 1
    td = threshold_diffs[0]
    assert "rail" in td
    assert "current" in td
    assert "suggested" in td

    assert len(principle_diffs) == 1
    pd = principle_diffs[0]
    assert "action" in pd
    assert pd["action"] in ("enable", "disable", "add")
    assert "id" in pd
    assert "reason" in pd


@pytest.mark.asyncio
async def test_analyze_aggregates_patterns(store):
    """Analyzer aggregates per-rail triggers, per-principle violations, outcome distribution
    and passes them to the judge model prompt."""
    from harness.critique.analyzer import analyze_traces

    # Write a mix: 8 "revised", 4 "fallback_hard_block", different principles
    base_ts = datetime.now(timezone.utc) - timedelta(hours=2)
    for i in range(8):
        ts = (base_ts + timedelta(seconds=i)).isoformat()
        await store.write(
            {
                "request_id": str(uuid.uuid4()),
                "tenant": "test-tenant",
                "timestamp": ts,
                "model": "llama3.1",
                "prompt": "Hello",
                "response": "World",
                "latency_ms": 100,
                "status_code": 200,
                "guardrail_decisions": None,
                "cai_critique": _make_cai_critique(
                    outcome="revised",
                    violated=["P-SAFETY-01"],
                ),
                "refusal_event": False,
                "bypass_flag": False,
            }
        )
    for i in range(4):
        ts = (base_ts + timedelta(seconds=100 + i)).isoformat()
        await store.write(
            {
                "request_id": str(uuid.uuid4()),
                "tenant": "test-tenant",
                "timestamp": ts,
                "model": "llama3.1",
                "prompt": "Hello",
                "response": "World",
                "latency_ms": 100,
                "status_code": 200,
                "guardrail_decisions": None,
                "cai_critique": _make_cai_critique(
                    outcome="fallback_hard_block",
                    violated=["P-SAFETY-01", "P-FAIRNESS-01"],
                ),
                "refusal_event": False,
                "bypass_flag": False,
            }
        )

    http_client = _make_http_client_mock()
    constitution = _make_constitution()
    since = (datetime.now(timezone.utc) - timedelta(hours=3)).isoformat()

    result = await analyze_traces(
        trace_store=store,
        http_client=http_client,
        constitution=constitution,
        since=since,
    )

    # Judge model should have been called once
    http_client.post.assert_called_once()

    # Verify the prompt content passed to judge contained aggregate stats
    call_kwargs = http_client.post.call_args
    body = call_kwargs[1].get("json") or call_kwargs[0][1]  # positional or kwarg
    messages = body.get("messages", [])
    # Find user message content
    user_content = next(
        (m["content"] for m in messages if m.get("role") == "user"), ""
    )
    # Aggregates should mention outcome counts or principle violations
    assert "P-SAFETY-01" in user_content or "revised" in user_content or "fallback" in user_content


@pytest.mark.asyncio
async def test_judge_parse_failure_graceful(store):
    """If judge returns invalid JSON, analyze_traces returns report with 'Analysis failed'
    and empty yaml_diffs — no exception raised."""
    from harness.critique.analyzer import analyze_traces

    await _write_n_traces(store, 15, with_critique=True)

    # Mock returns non-JSON content
    mock_response = MagicMock()
    mock_response.json.return_value = {
        "choices": [
            {
                "message": {
                    "content": "This is not valid JSON at all!!!",
                }
            }
        ]
    }
    http_client = MagicMock()
    http_client.post = AsyncMock(return_value=mock_response)

    constitution = _make_constitution()
    since = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()

    # Must not raise
    result = await analyze_traces(
        trace_store=store,
        http_client=http_client,
        constitution=constitution,
        since=since,
    )

    assert "Analysis failed" in result["report"]
    assert result["yaml_diffs"] == []
    assert "generated_at" in result
