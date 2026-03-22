"""Admin endpoints for tuning analysis and diagnostics."""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Query, Request
from fastapi.responses import JSONResponse

from harness.auth.bearer import verify_api_key
from harness.config.loader import TenantConfig

admin_router = APIRouter(prefix="/admin", tags=["admin"])


@admin_router.post("/suggest-tuning")
async def suggest_tuning(
    request: Request,
    tenant: TenantConfig = Depends(verify_api_key),
    since: str = Query(default="24h", description="Time window: ISO8601 timestamp or shorthand like '24h', '7d'"),
):
    """Trigger on-demand tuning analysis based on trace history.

    Returns ranked threshold + principle tuning suggestions as both
    human-readable report and machine-readable YAML diffs.
    """
    from harness.critique.analyzer import analyze_traces

    # Resolve shorthand time strings
    since_ts = _resolve_since(since)

    trace_store = request.app.state.trace_store
    http_client = request.app.state.http_client
    critique_engine = getattr(request.app.state, "critique_engine", None)
    constitution = critique_engine.constitution if critique_engine else None

    if constitution is None:
        return JSONResponse(
            content={"error": "Constitutional AI not configured"},
            status_code=503,
        )

    result = await analyze_traces(
        trace_store=trace_store,
        http_client=http_client,
        constitution=constitution,
        since=since_ts,
    )
    return JSONResponse(content=result)


def _resolve_since(since: str) -> str:
    """Convert shorthand like '24h', '7d' to ISO8601 timestamp."""
    now = datetime.now(timezone.utc)
    if since.endswith("h"):
        hours = int(since[:-1])
        return (now - timedelta(hours=hours)).isoformat()
    elif since.endswith("d"):
        days = int(since[:-1])
        return (now - timedelta(days=days)).isoformat()
    else:
        return since  # Assume ISO8601 already
