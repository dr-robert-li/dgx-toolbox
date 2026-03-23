"""Tests for red team active components: garak runner, deepteam engine, router, and CLI."""
from __future__ import annotations

import asyncio
import json
import os
import sys
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


# ---------------------------------------------------------------------------
# Task 2: Router tests — helpers
# ---------------------------------------------------------------------------


def _make_app(tmp_path: Path):
    """Create a minimal FastAPI test app with mocked state."""
    import asyncio
    from fastapi import FastAPI
    from harness.redteam.router import redteam_router

    app = FastAPI()
    app.include_router(redteam_router)

    # Fake trace store backed by in-memory dict
    jobs: dict = {}

    class FakeTraceStore:
        async def create_job(self, job: dict) -> None:
            jobs[job["job_id"]] = {
                "job_id": job["job_id"],
                "type": job["type"],
                "status": "pending",
                "created_at": job.get("created_at", "2026-01-01T00:00:00Z"),
                "completed_at": None,
                "result": None,
            }

        async def update_job_status(self, job_id: str, status: str, result: dict | None = None) -> None:
            if job_id in jobs:
                jobs[job_id]["status"] = status
                if result is not None:
                    jobs[job_id]["result"] = result

        async def get_job(self, job_id: str) -> dict | None:
            return jobs.get(job_id)

        async def list_jobs(self, limit: int = 20) -> list[dict]:
            return list(jobs.values())[-limit:]

    # Override verify_api_key dependency to always succeed
    from harness.config.loader import TenantConfig

    async def fake_verify_api_key():
        return TenantConfig(
            tenant_id="test",
            api_key_hash="$argon2id$v=19$m=65536,t=3,p=4$fakehash",
            bypass=True,
        )

    from harness.auth.bearer import verify_api_key
    app.dependency_overrides[verify_api_key] = fake_verify_api_key

    app.state.trace_store = FakeTraceStore()
    app.state.redteam_lock = asyncio.Lock()
    app.state.redteam_current_job_id = None
    app.state.redteam_active_task = None
    app.state.http_client = AsyncMock()
    app.state.critique_engine = None

    return app, jobs


# ---------------------------------------------------------------------------
# Task 2: Router tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_submit_garak_job(tmp_path):
    """POST /admin/redteam/jobs with type=garak returns 202 with job_id starting with rt-."""
    from httpx import ASGITransport, AsyncClient

    app, jobs = _make_app(tmp_path)

    # Patch _dispatch_garak to avoid actual subprocess
    with patch("harness.redteam.router._dispatch_garak", new=AsyncMock(return_value={"scores": {}})):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            resp = await client.post(
                "/admin/redteam/jobs",
                json={"type": "garak", "profile": "quick"},
                headers={"Authorization": "Bearer test-key"},
            )

    assert resp.status_code == 202
    data = resp.json()
    assert "job_id" in data
    assert data["job_id"].startswith("rt-")
    assert data["status"] == "pending"


@pytest.mark.asyncio
async def test_submit_deepteam_job(tmp_path):
    """POST /admin/redteam/jobs with type=deepteam returns 202 with job_id."""
    from httpx import ASGITransport, AsyncClient

    app, jobs = _make_app(tmp_path)

    with patch("harness.redteam.router._dispatch_deepteam", new=AsyncMock(return_value={"variants_generated": 0})):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            resp = await client.post(
                "/admin/redteam/jobs",
                json={"type": "deepteam"},
                headers={"Authorization": "Bearer test-key"},
            )

    assert resp.status_code == 202
    data = resp.json()
    assert "job_id" in data


@pytest.mark.asyncio
async def test_409_conflict(tmp_path):
    """Second job submission while one is running returns 409 Conflict with running job_id."""
    from httpx import ASGITransport, AsyncClient
    import asyncio

    app, jobs = _make_app(tmp_path)

    # Manually acquire the lock to simulate a running job
    await app.state.redteam_lock.acquire()
    app.state.redteam_current_job_id = "rt-running-job"

    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            resp = await client.post(
                "/admin/redteam/jobs",
                json={"type": "garak", "profile": "quick"},
                headers={"Authorization": "Bearer test-key"},
            )
    finally:
        app.state.redteam_lock.release()

    assert resp.status_code == 409
    data = resp.json()
    assert "error" in data
    assert data["job_id"] == "rt-running-job"


@pytest.mark.asyncio
async def test_get_job_status(tmp_path):
    """Submit a job, then GET /admin/redteam/jobs/{job_id} returns dict with job fields."""
    from httpx import ASGITransport, AsyncClient

    app, jobs = _make_app(tmp_path)

    with patch("harness.redteam.router._dispatch_garak", new=AsyncMock(return_value={"scores": {}})):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            post_resp = await client.post(
                "/admin/redteam/jobs",
                json={"type": "garak", "profile": "quick"},
                headers={"Authorization": "Bearer test-key"},
            )
            job_id = post_resp.json()["job_id"]

            get_resp = await client.get(
                f"/admin/redteam/jobs/{job_id}",
                headers={"Authorization": "Bearer test-key"},
            )

    assert get_resp.status_code == 200
    data = get_resp.json()
    assert data["job_id"] == job_id
    assert "type" in data
    assert "status" in data
    assert "created_at" in data


@pytest.mark.asyncio
async def test_get_job_404(tmp_path):
    """GET /admin/redteam/jobs/nonexistent returns 404."""
    from httpx import ASGITransport, AsyncClient

    app, jobs = _make_app(tmp_path)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        resp = await client.get(
            "/admin/redteam/jobs/nonexistent-job",
            headers={"Authorization": "Bearer test-key"},
        )

    assert resp.status_code == 404


@pytest.mark.asyncio
async def test_list_jobs(tmp_path):
    """Submit 2 jobs, GET /admin/redteam/jobs returns list of 2."""
    from httpx import ASGITransport, AsyncClient

    app, jobs = _make_app(tmp_path)

    with patch("harness.redteam.router._dispatch_garak", new=AsyncMock(return_value={"scores": {}})):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            for _ in range(2):
                await client.post(
                    "/admin/redteam/jobs",
                    json={"type": "garak", "profile": "quick"},
                    headers={"Authorization": "Bearer test-key"},
                )
            resp = await client.get(
                "/admin/redteam/jobs",
                headers={"Authorization": "Bearer test-key"},
            )

    assert resp.status_code == 200
    data = resp.json()
    assert "jobs" in data
    assert len(data["jobs"]) == 2


# ---------------------------------------------------------------------------
# Task 2: CLI promote tests
# ---------------------------------------------------------------------------


def _write_jsonl(path: Path, entries: list[dict]) -> None:
    path.write_text("\n".join(json.dumps(e) for e in entries))


def test_promote_cli_success(tmp_path, monkeypatch):
    """Pending JSONL within balance limits gets moved to active dir."""
    import harness.redteam.__main__ as cli_main

    active_dir = tmp_path / "active"
    active_dir.mkdir()
    pending_dir = tmp_path / "pending"
    pending_dir.mkdir()

    pending_file = pending_dir / "deepteam-20260323T120000.jsonl"
    _write_jsonl(pending_file, [
        {"prompt": "test1", "category": "injection", "expected_action": "block"},
        {"prompt": "test2", "category": "violence", "expected_action": "block"},
    ])

    monkeypatch.setattr(cli_main, "ACTIVE_DIR", active_dir)
    monkeypatch.setattr(cli_main, "PENDING_DIR", pending_dir)

    args = MagicMock()
    args.file = str(pending_file)
    args.max_ratio = 0.40

    # Should not raise — within balance limits (50% each, but max ratio 0.40 means we need to check)
    # With 2 entries: injection=1/2=0.5, violence=1/2=0.5, both exceed 0.40
    # Let's use 3 categories to stay within 0.40
    pending_file.write_text(
        "\n".join(json.dumps(e) for e in [
            {"prompt": "test1", "category": "injection", "expected_action": "block"},
            {"prompt": "test2", "category": "violence", "expected_action": "block"},
            {"prompt": "test3", "category": "roleplay", "expected_action": "block"},
        ])
    )

    cli_main.cmd_promote(args)

    dest = active_dir / pending_file.name
    assert dest.exists(), "File should have been moved to active dir"
    assert not pending_file.exists(), "File should have been removed from pending dir"


def test_promote_cli_balance_failure(tmp_path, monkeypatch):
    """Pending JSONL exceeding balance causes sys.exit(1), file NOT moved."""
    import harness.redteam.__main__ as cli_main

    active_dir = tmp_path / "active"
    active_dir.mkdir()
    pending_dir = tmp_path / "pending"
    pending_dir.mkdir()

    pending_file = pending_dir / "deepteam-20260323T120001.jsonl"
    # 4 out of 5 are injection -> 80% > 40% cap
    _write_jsonl(pending_file, [
        {"prompt": f"inj-{i}", "category": "injection", "expected_action": "block"}
        for i in range(4)
    ] + [{"prompt": "other", "category": "other", "expected_action": "block"}])

    monkeypatch.setattr(cli_main, "ACTIVE_DIR", active_dir)
    monkeypatch.setattr(cli_main, "PENDING_DIR", pending_dir)

    args = MagicMock()
    args.file = str(pending_file)
    args.max_ratio = 0.40

    with pytest.raises(SystemExit) as exc_info:
        cli_main.cmd_promote(args)

    assert exc_info.value.code == 1
    # File should NOT have been moved
    assert pending_file.exists(), "File should remain in pending dir on balance failure"
    dest = active_dir / pending_file.name
    assert not dest.exists(), "File should NOT be in active dir after failed balance check"
