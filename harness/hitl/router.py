"""HITL admin endpoints: priority queue and correction submission."""
from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, Depends, Query, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from harness.auth.bearer import verify_api_key
from harness.config.loader import TenantConfig
from harness.proxy.admin import _resolve_since

hitl_router = APIRouter(prefix="/admin/hitl", tags=["hitl"])


class CorrectionRequest(BaseModel):
    """Payload for POST /admin/hitl/correct."""

    request_id: str
    reviewer: str
    action: Literal["approve", "reject", "edit"]
    edited_response: str | None = None
    trace_ref: str | None = None


@hitl_router.get("/queue")
async def get_hitl_queue(
    request: Request,
    tenant: TenantConfig = Depends(verify_api_key),
    rail: str = Query(default="all"),
    tenant_filter: str = Query(default="all", alias="tenant"),
    since: str = Query(default="24h"),
    hide_reviewed: bool = Query(default=False),
) -> JSONResponse:
    """Return the HITL review queue, priority-sorted.

    Items are sorted by review urgency: closest-to-threshold flagged traces
    appear first; already-reviewed items sort to the bottom.

    Query parameters:
        rail: Filter by triggering rail name, or 'all' (default).
        tenant: Filter by tenant ID, or 'all' (default).
        since: Time window — ISO8601 timestamp or shorthand like '24h', '7d'.
        hide_reviewed: If true, exclude traces that have corrections.
    """
    since_ts = _resolve_since(since)
    trace_store = request.app.state.trace_store
    results = await trace_store.query_hitl_queue(
        since=since_ts,
        rail_filter=rail,
        tenant_filter=tenant_filter,
        hide_reviewed=hide_reviewed,
    )
    return JSONResponse(content={"queue": results, "count": len(results)})


@hitl_router.post("/correct")
async def submit_correction(
    request: Request,
    body: CorrectionRequest,
    tenant: TenantConfig = Depends(verify_api_key),
) -> JSONResponse:
    """Submit a human correction for a flagged trace.

    Action must be one of: approve, reject, edit.
    When action is 'edit', edited_response should contain the corrected text
    (PII will be redacted before storage).
    """
    trace_store = request.app.state.trace_store
    await trace_store.write_correction(body.model_dump())
    return JSONResponse(content={"status": "ok", "request_id": body.request_id})
