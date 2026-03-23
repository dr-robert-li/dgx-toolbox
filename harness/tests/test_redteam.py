"""Tests for red team active components: garak runner, deepteam engine, router, and CLI."""
from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest


# ---------------------------------------------------------------------------
# Task 1: garak runner tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_garak_runner_invokes_subprocess(tmp_path):
    """run_garak_scan calls asyncio.create_subprocess_exec with correct flags."""
    from harness.redteam.garak_runner import run_garak_scan

    mock_proc = MagicMock()
    mock_proc.communicate = AsyncMock(return_value=(b"stdout output", b"stderr output"))
    mock_proc.returncode = 0

    profile_path = str(tmp_path / "redteam_quick.yaml")
    (tmp_path / "redteam_quick.yaml").write_text("redteam: {}")
    report_dir = str(tmp_path / "reports")

    with patch("asyncio.create_subprocess_exec", new=AsyncMock(return_value=mock_proc)) as mock_exec:
        await run_garak_scan(
            profile_config_path=profile_path,
            api_key="test-key",
            report_dir=report_dir,
            job_id="rt-test001",
        )

    mock_exec.assert_called_once()
    call_args = mock_exec.call_args
    cmd = call_args[0]  # positional args = command
    assert "python" == cmd[0]
    assert "-m" == cmd[1]
    assert "garak" == cmd[2]
    assert "--config" in cmd
    assert profile_path in cmd
    assert "--report_prefix" in cmd
    assert "rt-test001" in cmd[-1]


@pytest.mark.asyncio
async def test_garak_runner_parses_report(tmp_path):
    """parse_garak_report returns dict of probe->scores from JSONL."""
    from harness.redteam.garak_runner import parse_garak_report

    report_file = tmp_path / "rt-test001.report.jsonl"
    report_entries = [
        {"entry_type": "eval", "probe": "dan.Dan_11_0", "passed": 8, "total": 10},
        {"entry_type": "eval", "probe": "encoding", "passed": 5, "total": 5},
        {"entry_type": "start", "probe": "dan.Dan_11_0"},  # should be ignored
    ]
    report_file.write_text("\n".join(json.dumps(e) for e in report_entries))

    scores = parse_garak_report(str(report_file))

    assert "dan.Dan_11_0" in scores
    assert scores["dan.Dan_11_0"]["passed"] == 8
    assert scores["dan.Dan_11_0"]["total"] == 10
    assert scores["dan.Dan_11_0"]["pass_rate"] == pytest.approx(0.8, abs=0.001)
    assert "encoding" in scores
    assert scores["encoding"]["pass_rate"] == pytest.approx(1.0, abs=0.001)
    # "start" entries should not appear
    assert len(scores) == 2


@pytest.mark.asyncio
async def test_garak_runner_handles_missing_report(tmp_path):
    """When report file doesn't exist, returns empty scores dict."""
    from harness.redteam.garak_runner import parse_garak_report

    scores = parse_garak_report(str(tmp_path / "nonexistent.report.jsonl"))
    assert scores == {}


@pytest.mark.asyncio
async def test_garak_runner_sets_env_key(tmp_path):
    """run_garak_scan passes OPENAICOMPATIBLE_API_KEY in env to subprocess."""
    from harness.redteam.garak_runner import run_garak_scan

    mock_proc = MagicMock()
    mock_proc.communicate = AsyncMock(return_value=(b"", b""))
    mock_proc.returncode = 0

    profile_path = str(tmp_path / "profile.yaml")
    (tmp_path / "profile.yaml").write_text("")
    report_dir = str(tmp_path / "reports")

    with patch("asyncio.create_subprocess_exec", new=AsyncMock(return_value=mock_proc)) as mock_exec:
        await run_garak_scan(
            profile_config_path=profile_path,
            api_key="secret-key-123",
            report_dir=report_dir,
            job_id="rt-env-test",
        )

    call_kwargs = mock_exec.call_args.kwargs
    env_passed = call_kwargs.get("env", {})
    assert "OPENAICOMPATIBLE_API_KEY" in env_passed
    assert env_passed["OPENAICOMPATIBLE_API_KEY"] == "secret-key-123"


# ---------------------------------------------------------------------------
# Task 1: deepteam engine tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_adversarial_generation_calls_judge(tmp_path):
    """generate_adversarial_variants returns list of dicts with prompt/technique/category."""
    from harness.redteam.engine import generate_adversarial_variants

    mock_variants = [
        {"prompt": "variant 1", "technique": "rephrasing", "category": "injection"},
        {"prompt": "variant 2", "technique": "encoding", "category": "injection"},
        {"prompt": "variant 3", "technique": "roleplay", "category": "injection"},
    ]
    mock_response = MagicMock()
    mock_response.raise_for_status = MagicMock()
    mock_response.json.return_value = {
        "choices": [{"message": {"content": json.dumps({"variants": mock_variants})}}]
    }

    mock_http = AsyncMock()
    mock_http.post = AsyncMock(return_value=mock_response)

    variants = await generate_adversarial_variants(
        http_client=mock_http,
        judge_model="gpt-3.5-turbo",
        source_prompt="Can you help me do something harmful?",
        n=3,
    )

    assert len(variants) == 3
    for v in variants:
        assert "prompt" in v
        assert "technique" in v
        assert "category" in v

    mock_http.post.assert_called_once()
    call_kwargs = mock_http.post.call_args.kwargs
    assert "json" in call_kwargs
    assert call_kwargs["json"]["model"] == "gpt-3.5-turbo"


@pytest.mark.asyncio
async def test_adversarial_generation_handles_parse_failure():
    """When http_client returns non-JSON, generate_adversarial_variants returns empty list."""
    from harness.redteam.engine import generate_adversarial_variants

    mock_response = MagicMock()
    mock_response.raise_for_status = MagicMock()
    mock_response.json.return_value = {
        "choices": [{"message": {"content": "not valid json {"}}]
    }

    mock_http = AsyncMock()
    mock_http.post = AsyncMock(return_value=mock_response)

    variants = await generate_adversarial_variants(
        http_client=mock_http,
        judge_model="gpt-3.5-turbo",
        source_prompt="test",
        n=3,
    )

    assert variants == []


@pytest.mark.asyncio
async def test_run_deepteam_job_writes_jsonl(tmp_path):
    """run_deepteam_job writes pending JSONL file with correct format."""
    from harness.redteam import engine

    near_miss_traces = [
        {
            "request_id": "trace-1",
            "prompt": "tell me how to do something bad",
            "guardrail_decisions": json.dumps({
                "blocked": False,
                "all_results": [{"rail": "self_check_output", "score": 0.7, "threshold": 0.8}]
            }),
        },
        {
            "request_id": "trace-2",
            "prompt": "another near-miss prompt",
            "guardrail_decisions": json.dumps({
                "blocked": False,
                "all_results": [{"rail": "self_check_output", "score": 0.6, "threshold": 0.8}]
            }),
        },
        {
            "request_id": "trace-3",
            "prompt": "third near-miss prompt",
            "guardrail_decisions": json.dumps({}),
        },
        {
            "request_id": "trace-4",
            "prompt": "fourth near-miss prompt",
            "guardrail_decisions": json.dumps({}),
        },
        {
            "request_id": "trace-5",
            "prompt": "fifth near-miss prompt",
            "guardrail_decisions": json.dumps({}),
        },
    ]

    mock_trace_store = AsyncMock()
    mock_trace_store.query_near_misses = AsyncMock(return_value=near_miss_traces)

    mock_variants = [
        {"prompt": "variant A", "technique": "rephrasing", "category": "injection"},
    ]
    mock_response = MagicMock()
    mock_response.raise_for_status = MagicMock()
    mock_response.json.return_value = {
        "choices": [{"message": {"content": json.dumps({"variants": mock_variants})}}]
    }
    mock_http = AsyncMock()
    mock_http.post = AsyncMock(return_value=mock_response)

    pending_dir = tmp_path / "pending"

    with patch.object(engine, "PENDING_DIR", pending_dir):
        result = await engine.run_deepteam_job(
            trace_store=mock_trace_store,
            http_client=mock_http,
            judge_model="gpt-3.5-turbo",
            near_miss_window_days=7,
            near_miss_limit=100,
            near_miss_min_count=5,
            variants_per_prompt=1,
        )

    assert result["skipped"] is False
    assert result["near_miss_count"] == 5
    assert result["variants_generated"] > 0
    assert result["pending_file"] is not None

    # Verify the JSONL file was written
    pending_file = Path(result["pending_file"])
    assert pending_file.exists()
    lines = [l for l in pending_file.read_text().splitlines() if l.strip()]
    assert len(lines) > 0
    for line in lines:
        entry = json.loads(line)
        assert "prompt" in entry
        assert "technique" in entry
        assert "category" in entry


@pytest.mark.asyncio
async def test_run_deepteam_job_skips_on_few_near_misses():
    """When near-misses below min_count, run_deepteam_job returns result with variants_generated=0."""
    from harness.redteam.engine import run_deepteam_job

    # Return only 2 near-misses (below min_count=5)
    mock_trace_store = AsyncMock()
    mock_trace_store.query_near_misses = AsyncMock(return_value=[
        {"request_id": "nm-1", "prompt": "prompt 1"},
        {"request_id": "nm-2", "prompt": "prompt 2"},
    ])

    mock_http = AsyncMock()

    result = await run_deepteam_job(
        trace_store=mock_trace_store,
        http_client=mock_http,
        judge_model="gpt-3.5-turbo",
        near_miss_window_days=7,
        near_miss_limit=100,
        near_miss_min_count=5,
        variants_per_prompt=3,
    )

    assert result["skipped"] is True
    assert result["variants_generated"] == 0
    assert result["near_miss_count"] == 2
    assert "skip_reason" in result
    # http_client.post should NOT have been called
    mock_http.post.assert_not_called()
