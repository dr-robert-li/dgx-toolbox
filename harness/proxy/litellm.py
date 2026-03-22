"""Proxy route to LiteLLM with auth, rate limiting, PII redaction, and trace write."""
from __future__ import annotations

import json
import time
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse
from starlette.background import BackgroundTask

from harness.auth.bearer import verify_api_key
from harness.config.loader import TenantConfig
from harness.pii.redactor import redact
from harness.ratelimit.sliding_window import RateLimitExceeded

router = APIRouter()


@router.post("/v1/chat/completions")
async def chat_completions(
    request: Request,
    tenant: TenantConfig = Depends(verify_api_key),
) -> JSONResponse:
    """Proxy /v1/chat/completions to LiteLLM with auth, rate limiting, and tracing.

    Pipeline:
    1. RPM check (pre-request)
    2. TPM check (checks previous request's accumulated tokens)
    3. Proxy body to LiteLLM
    4. Record TPM for this response (gates the next request)
    5. PII redact + trace write in background after response sent
    """
    rate_limiter = request.app.state.rate_limiter

    # 1. RPM check
    try:
        await rate_limiter.check_rpm(tenant.tenant_id, tenant.rpm_limit)
    except RateLimitExceeded as exc:
        raise HTTPException(status_code=429, detail=str(exc))

    # 2. TPM check (one-request lag)
    try:
        await rate_limiter.check_tpm(tenant.tenant_id, tenant.tpm_limit)
    except RateLimitExceeded as exc:
        raise HTTPException(status_code=429, detail=str(exc))

    # 3. Read request body and forward to LiteLLM
    body = await request.json()
    request_id = str(uuid.uuid4())
    start_time = time.monotonic()

    http_client = request.app.state.http_client
    resp = await http_client.post("/v1/chat/completions", json=body)
    latency_ms = int((time.monotonic() - start_time) * 1000)

    response_data = resp.json()

    # 4. Record actual token usage for next request's TPM gate
    usage = response_data.get("usage") or {}
    total_tokens = usage.get("total_tokens", 0)
    if total_tokens > 0:
        await rate_limiter.record_tpm(tenant.tenant_id, total_tokens)

    # 5. PII redact + trace write in background (after response is sent to client)
    background = BackgroundTask(
        _write_trace,
        app=request.app,
        request_id=request_id,
        tenant=tenant,
        body=body,
        response_data=response_data,
        latency_ms=latency_ms,
        status_code=resp.status_code,
    )
    return JSONResponse(
        content=response_data,
        status_code=resp.status_code,
        background=background,
    )


async def _write_trace(
    app,
    request_id: str,
    tenant: TenantConfig,
    body: dict,
    response_data: dict,
    latency_ms: int,
    status_code: int,
) -> None:
    """Extract, PII-redact, and write a trace record to SQLite.

    Called as a BackgroundTask after the response has been sent to the client.
    Raw PII never persists — redaction happens before any SQLite write.
    """
    # Extract prompt from messages (join all content fields)
    messages = body.get("messages", [])
    prompt_parts: list[str] = []
    for msg in messages:
        content = msg.get("content")
        if isinstance(content, str):
            prompt_parts.append(content)
        elif isinstance(content, list):
            # Multi-modal content: extract text parts
            for part in content:
                if isinstance(part, dict) and part.get("type") == "text":
                    prompt_parts.append(part.get("text", ""))
    prompt = " ".join(prompt_parts) if prompt_parts else json.dumps(messages)

    # Extract response text
    choices = response_data.get("choices") or []
    if choices:
        response_text = choices[0].get("message", {}).get("content") or json.dumps(
            response_data
        )
    else:
        response_text = json.dumps(response_data)

    # PII redact before any write
    redacted_prompt = redact(prompt, tenant.pii_strictness)
    redacted_response = redact(response_text, tenant.pii_strictness)

    record = {
        "request_id": request_id,
        "tenant": tenant.tenant_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "model": body.get("model", "unknown"),
        "prompt": redacted_prompt,
        "response": redacted_response,
        "latency_ms": latency_ms,
        "status_code": status_code,
        "guardrail_decisions": None,  # Phase 6
        "cai_critique": None,  # Phase 7
        "refusal_event": False,
        "bypass_flag": tenant.bypass,
    }

    await app.state.trace_store.write(record)
