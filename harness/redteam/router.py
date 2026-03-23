"""Red team admin endpoints with async single-job dispatch."""
from __future__ import annotations

import asyncio
import os
import uuid
from datetime import datetime, timezone
from typing import Optional

import yaml
from fastapi import APIRouter, Depends, Query, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from harness.auth.bearer import verify_api_key
from harness.config.loader import TenantConfig

redteam_router = APIRouter(prefix="/admin/redteam", tags=["redteam"])

# Probe lists for each profile (passed via --probes CLI flag, not in YAML)
PROFILE_PROBES = {
    "quick": "dan.Dan_11_0,encoding,promptinject",
    "standard": "dan.Dan_11_0,encoding,promptinject,lmrc.Profanity,lmrc.Violence,knownbadsignatures",
    "thorough": "dan.Dan_11_0,encoding,promptinject,lmrc.Profanity,lmrc.Violence,knownbadsignatures,continuation,divergence",
}


class JobRequest(BaseModel):
    type: str  # "garak" or "deepteam"
    profile: str = "quick"  # garak profile name (ignored for deepteam)


@redteam_router.post("/jobs")
async def submit_job(
    request: Request,
    body: JobRequest,
    tenant: TenantConfig = Depends(verify_api_key),
):
    """Submit a red team job. Returns 202 Accepted with job_id, or 409 if a job is running."""
    lock: asyncio.Lock = request.app.state.redteam_lock
    if lock.locked():
        current_id = request.app.state.redteam_current_job_id
        return JSONResponse(
            status_code=409,
            content={"error": "A red team job is already running", "job_id": current_id},
        )

    if body.type not in ("garak", "deepteam"):
        return JSONResponse(status_code=400, content={"error": "type must be 'garak' or 'deepteam'"})

    job_id = f"rt-{uuid.uuid4().hex[:12]}"
    now = datetime.now(timezone.utc).isoformat()

    trace_store = request.app.state.trace_store
    await trace_store.create_job({"job_id": job_id, "type": body.type, "created_at": now})

    # Store task reference to prevent GC (Pitfall 3 from research)
    task = asyncio.create_task(_run_job(request.app, job_id, body))
    request.app.state.redteam_active_task = task

    return JSONResponse(status_code=202, content={"job_id": job_id, "status": "pending"})


async def _run_job(app, job_id: str, body: JobRequest):
    """Background task that acquires the lock, runs the job, and updates status."""
    async with app.state.redteam_lock:
        app.state.redteam_current_job_id = job_id
        trace_store = app.state.trace_store
        await trace_store.update_job_status(job_id, "running")
        try:
            if body.type == "garak":
                result = await _dispatch_garak(app, job_id, body.profile)
            else:
                result = await _dispatch_deepteam(app, job_id)
            await trace_store.update_job_status(job_id, "complete", result)
        except Exception as e:
            await trace_store.update_job_status(job_id, "failed", {"error": str(e)})
        finally:
            app.state.redteam_current_job_id = None
            app.state.redteam_active_task = None


async def _dispatch_garak(app, job_id: str, profile: str) -> dict:
    """Run a garak scan job."""
    from harness.redteam.garak_runner import run_garak_scan

    config_dir = os.environ.get(
        "HARNESS_CONFIG_DIR",
        os.path.join(os.path.dirname(os.path.dirname(__file__)), "config"),
    )

    # Load redteam config for gateway URL
    redteam_config_path = os.path.join(config_dir, "redteam.yaml")
    with open(redteam_config_path) as f:
        redteam_cfg = yaml.safe_load(f).get("redteam", {})

    profile_path = os.path.join(config_dir, f"redteam_{profile}.yaml")
    if not os.path.exists(profile_path):
        return {"error": f"Profile '{profile}' not found at {profile_path}"}

    # Use a dedicated redteam API key if configured, or first tenant key
    api_key = os.environ.get("REDTEAM_API_KEY", "")

    data_dir = os.environ.get(
        "HARNESS_DATA_DIR",
        os.path.join(os.path.dirname(os.path.dirname(__file__)), "data"),
    )
    report_dir = os.path.join(data_dir, "garak-runs")

    probes = PROFILE_PROBES.get(profile)

    result = await run_garak_scan(
        profile_config_path=profile_path,
        api_key=api_key,
        report_dir=report_dir,
        job_id=job_id,
        probes=probes,
    )

    return {
        "profile": profile,
        "gateway_url": redteam_cfg.get("gateway_url", "http://localhost:8080"),
        "scores": result["scores"],
        "report_path": result["report_path"],
        "exit_code": result["exit_code"],
        "stderr_tail": result["stderr"][-500:] if result.get("stderr") else "",
    }


async def _dispatch_deepteam(app, job_id: str) -> dict:
    """Run a deepteam adversarial generation job."""
    from harness.redteam.engine import run_deepteam_job

    config_dir = os.environ.get(
        "HARNESS_CONFIG_DIR",
        os.path.join(os.path.dirname(os.path.dirname(__file__)), "config"),
    )
    redteam_config_path = os.path.join(config_dir, "redteam.yaml")
    with open(redteam_config_path) as f:
        redteam_cfg = yaml.safe_load(f).get("redteam", {})

    # Resolve judge model from constitution config
    critique_engine = getattr(app.state, "critique_engine", None)
    if critique_engine and critique_engine.constitution:
        judge_model = critique_engine.constitution.judge_model
        if judge_model == "default":
            judge_model = "gpt-3.5-turbo"  # Sensible default when "default" is set
    else:
        judge_model = "gpt-3.5-turbo"

    return await run_deepteam_job(
        trace_store=app.state.trace_store,
        http_client=app.state.http_client,
        judge_model=judge_model,
        near_miss_window_days=redteam_cfg.get("near_miss_window_days", 7),
        near_miss_limit=redteam_cfg.get("near_miss_limit", 100),
        near_miss_min_count=redteam_cfg.get("near_miss_min_count", 5),
        variants_per_prompt=redteam_cfg.get("variants_per_prompt", 3),
    )


@redteam_router.get("/jobs/{job_id}")
async def get_job_status(
    request: Request,
    job_id: str,
    tenant: TenantConfig = Depends(verify_api_key),
):
    """Get status and result of a red team job by ID."""
    job = await request.app.state.trace_store.get_job(job_id)
    if job is None:
        return JSONResponse(status_code=404, content={"error": f"Job {job_id} not found"})
    return JSONResponse(content=job)


@redteam_router.get("/jobs")
async def list_jobs(
    request: Request,
    tenant: TenantConfig = Depends(verify_api_key),
    limit: int = Query(default=20, le=100),
):
    """List recent red team jobs."""
    jobs = await request.app.state.trace_store.list_jobs(limit=limit)
    return JSONResponse(content={"jobs": jobs})
