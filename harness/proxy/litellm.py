"""Proxy route to LiteLLM with auth, rate limiting, guardrails, PII redaction, and trace write."""
from __future__ import annotations

import dataclasses
import json
import logging
import time
import uuid

logger = logging.getLogger("harness.proxy")
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse
from starlette.background import BackgroundTask

from harness.auth.bearer import verify_api_key
from harness.config.loader import TenantConfig
from harness.guards.normalizer import normalize_messages
from harness.guards.types import GuardrailDecision
from harness.pii.redactor import redact
from harness.ratelimit.sliding_window import RateLimitExceeded

router = APIRouter()


@router.post("/v1/chat/completions")
async def chat_completions(
    request: Request,
    tenant: TenantConfig = Depends(verify_api_key),
) -> JSONResponse:
    """Proxy /v1/chat/completions to LiteLLM with auth, rate limiting, guardrails, and tracing.

    Pipeline:
    1. RPM check (pre-request)
    2. TPM check (checks previous request's accumulated tokens)
    3. Read request body
    4. Guardrail pipeline (skip for bypass tenants):
       a. Unicode normalize
       b. Input rails
       c. If blocked: return refusal or soft-steer to LiteLLM
    5. Proxy body to LiteLLM
    6. Record TPM for this response (gates the next request)
    7. Output rails (skip for bypass tenants)
    8. PII redact + trace write in background after response sent
    """
    rate_limiter = request.app.state.rate_limiter

    # 1. RPM check
    try:
        await rate_limiter.check_rpm(tenant.tenant_id, tenant.rpm_limit)
    except RateLimitExceeded as exc:
        logger.warning("429 RPM: tenant=%s limit=%d detail=%s", tenant.tenant_id, tenant.rpm_limit, exc.detail)
        raise HTTPException(status_code=429, detail=str(exc))

    # 2. TPM check (one-request lag)
    try:
        await rate_limiter.check_tpm(tenant.tenant_id, tenant.tpm_limit)
    except RateLimitExceeded as exc:
        logger.warning("429 TPM: tenant=%s limit=%d detail=%s", tenant.tenant_id, tenant.tpm_limit, exc.detail)
        raise HTTPException(status_code=429, detail=str(exc))

    # 3. Read request body
    body = await request.json()
    request_id = str(uuid.uuid4())
    start_time = time.monotonic()
    guardrail_decisions_json = None
    is_refusal = False
    input_decision = None
    output_decision = None

    # 4. Guardrail pipeline (skip for bypass tenants)
    if not tenant.bypass:
        guardrail_engine = getattr(request.app.state, "guardrail_engine", None)

        if guardrail_engine is not None:
            # 4a. Unicode normalize
            messages = body.get("messages", [])
            normalized_messages, evasion_flags = normalize_messages(messages)
            body["messages"] = normalized_messages

            # 4b. Input rails — run all, collect violations
            input_decision = await guardrail_engine.check_input(
                messages=normalized_messages,
                tenant=tenant,
                evasion_flags=evasion_flags,
            )

            if input_decision.blocked:
                is_refusal = True
                # Collect all rail results for trace
                guardrail_decisions_json = [
                    dataclasses.asdict(r) for r in input_decision.all_results
                ]

                if input_decision.refusal_mode == "soft_steer":
                    # Soft steer: rewrite and send to LiteLLM
                    steer_messages = guardrail_engine._build_soft_steer_messages(
                        normalized_messages
                    )
                    http_client = request.app.state.http_client
                    resp = await http_client.post(
                        "/v1/chat/completions",
                        json={**body, "messages": steer_messages},
                    )
                    latency_ms = int((time.monotonic() - start_time) * 1000)
                    response_data = resp.json()
                    # Record TPM
                    usage = response_data.get("usage") or {}
                    total_tokens = usage.get("total_tokens", 0)
                    if total_tokens > 0:
                        await rate_limiter.record_tpm(tenant.tenant_id, total_tokens)
                    # Trace + return steered response
                    background = BackgroundTask(
                        _write_trace,
                        app=request.app,
                        request_id=request_id,
                        tenant=tenant,
                        body=body,
                        response_data=response_data,
                        latency_ms=latency_ms,
                        status_code=resp.status_code,
                        guardrail_decisions=guardrail_decisions_json,
                        is_refusal=is_refusal,
                        cai_critique=None,
                    )
                    return JSONResponse(
                        content=response_data,
                        status_code=resp.status_code,
                        background=background,
                    )
                else:
                    # Hard block or informative: return refusal, model NOT called
                    latency_ms = int((time.monotonic() - start_time) * 1000)
                    response_data = input_decision.replacement_response
                    background = BackgroundTask(
                        _write_trace,
                        app=request.app,
                        request_id=request_id,
                        tenant=tenant,
                        body=body,
                        response_data=response_data,
                        latency_ms=latency_ms,
                        status_code=400,
                        guardrail_decisions=guardrail_decisions_json,
                        is_refusal=is_refusal,
                        cai_critique=None,
                    )
                    return JSONResponse(
                        content=response_data,
                        status_code=400,
                        background=background,
                    )

    # 5. Proxy to LiteLLM (input passed or bypass tenant)
    http_client = request.app.state.http_client
    resp = await http_client.post("/v1/chat/completions", json=body)
    latency_ms = int((time.monotonic() - start_time) * 1000)
    response_data = resp.json()
    if resp.status_code >= 400:
        logger.warning("LiteLLM %d: model=%s error=%s", resp.status_code, body.get("model"), str(response_data)[:200])

    # 6. Record actual token usage for next request's TPM gate
    usage = response_data.get("usage") or {}
    total_tokens = usage.get("total_tokens", 0)
    if total_tokens > 0:
        await rate_limiter.record_tpm(tenant.tenant_id, total_tokens)

    # 7. Output rails (skip for bypass tenants)
    if not tenant.bypass:
        guardrail_engine = getattr(request.app.state, "guardrail_engine", None)
        if guardrail_engine is not None:
            output_decision = await guardrail_engine.check_output(
                response_data=response_data,
                tenant=tenant,
            )
            # Collect output rail results combined with any input rail results
            all_results = []
            if input_decision and input_decision.all_results:
                all_results.extend(input_decision.all_results)
            all_results.extend(output_decision.all_results)
            guardrail_decisions_json = [
                dataclasses.asdict(r) for r in all_results
            ]
            if output_decision.blocked:
                is_refusal = True
                response_data = output_decision.replacement_response

    # 7b. Critique loop (risk-gated — runs only when output rails pass but score is high-risk)
    cai_critique_data = None
    if not tenant.bypass and not is_refusal:
        critique_engine = getattr(request.app.state, "critique_engine", None)
        if critique_engine is not None and output_decision is not None:
            critique_result = await critique_engine.run_critique_loop(
                response_data=response_data,
                output_results=output_decision.all_results,
                request_model=body.get("model", "unknown"),
                http_client=request.app.state.http_client,
                pii_strictness=tenant.pii_strictness,
            )
            if critique_result is not None:
                cai_critique_data = critique_result
                if critique_result.get("fallback_hard_block"):
                    is_refusal = True
                    guardrail_engine = getattr(request.app.state, "guardrail_engine", None)
                    if guardrail_engine is not None:
                        response_data = guardrail_engine._build_hard_block_refusal("cai_critique")
                else:
                    # Replace response content with revised text
                    if response_data.get("choices"):
                        response_data["choices"][0]["message"]["content"] = (
                            critique_result["judge_response"]["revision"]
                        )

    # 8. PII redact + trace write in background (after response is sent to client)
    background = BackgroundTask(
        _write_trace,
        app=request.app,
        request_id=request_id,
        tenant=tenant,
        body=body,
        response_data=response_data,
        latency_ms=latency_ms,
        status_code=resp.status_code,
        guardrail_decisions=guardrail_decisions_json,
        is_refusal=is_refusal,
        cai_critique=cai_critique_data,
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
    guardrail_decisions=None,
    is_refusal: bool = False,
    cai_critique=None,
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
    choices = (response_data or {}).get("choices") or []
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
        "guardrail_decisions": guardrail_decisions,
        "cai_critique": cai_critique,
        "refusal_event": is_refusal,
        "bypass_flag": tenant.bypass,
    }

    await app.state.trace_store.write(record)
