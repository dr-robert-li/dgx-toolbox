"""Replay evaluation harness for curated safety/refusal datasets.

Sends each JSONL test case through the live gateway, measures latency,
scores results using classification metrics, and stores the eval run in SQLite.
"""
from __future__ import annotations

import asyncio
import json
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import httpx

from harness.eval.metrics import compute_metrics, compute_latency_percentiles
from harness.traces.store import TraceStore


async def run_replay(
    dataset_path: str,
    gateway_base_url: str,
    api_key: str,
    trace_store: TraceStore,
    model: str = "llama3.1",
) -> dict:
    """Load a JSONL dataset and replay each case through the gateway.

    Args:
        dataset_path: Path to a JSONL file. Each line must have fields:
                      prompt, expected_action, category, description.
        gateway_base_url: Base URL for the gateway (e.g., "http://localhost:8080").
        api_key: Bearer token for gateway authentication.
        trace_store: Initialized TraceStore instance for writing eval run records.
        model: LLM model identifier passed in each request body.

    Returns:
        Dict with keys:
            run_id        — unique identifier for this eval run
            total_cases   — number of cases replayed
            metrics       — F1/precision/recall/CRR/FRR/latency/critique_trigger_rate
            per_case_results — list of per-case result dicts
    """
    # Load JSONL dataset
    cases: list[dict] = []
    for line in Path(dataset_path).read_text().splitlines():
        line = line.strip()
        if line:
            cases.append(json.loads(line))

    run_id = f"replay-{uuid.uuid4().hex[:12]}"
    run_start = datetime.now(timezone.utc).isoformat()

    results: list[dict] = []

    async with httpx.AsyncClient(base_url=gateway_base_url, timeout=180.0) as client:
        for i, case in enumerate(cases):
            # Retry on 429 (rate limited), 404/502/503 (transient backend errors),
            # and timeouts with exponential backoff.  The sliding window is 60 s,
            # so the final sleep must be long enough to let the window drain.
            # Schedule: 2s, 4s, 8s, 16s, 65s  (worst-case: full 60s window flush)
            _retry_delays = [2, 4, 8, 16, 65]
            resp = None
            for attempt in range(len(_retry_delays) + 1):
                t0 = time.monotonic()
                try:
                    resp = await client.post(
                        "/v1/chat/completions",
                        headers={"Authorization": f"Bearer {api_key}"},
                        json={
                            "model": model,
                            "messages": [{"role": "user", "content": case["prompt"]}],
                        },
                    )
                except httpx.TimeoutException:
                    resp = None
                    latency_ms = int((time.monotonic() - t0) * 1000)
                    if attempt < len(_retry_delays):
                        await asyncio.sleep(_retry_delays[attempt])
                    continue
                latency_ms = int((time.monotonic() - t0) * 1000)
                if resp.status_code not in (429, 404, 502, 503):
                    break
                if attempt < len(_retry_delays):
                    await asyncio.sleep(_retry_delays[attempt])

            # Classify outcome:
            #   400/403/422 → guardrail block (expected for safety cases)
            #   any other non-2xx → error (not a meaningful block/allow signal)
            #   timeout (resp is None) → error
            if resp is None:
                actual_action = "error"
            elif resp.status_code in (400, 403, 422):
                actual_action = "block"
            elif 200 <= resp.status_code < 300:
                actual_action = "allow"
            else:
                # 429 exhausted, 404 backend missing, 5xx — record as error
                actual_action = "error"
            results.append(
                {
                    "case": case,
                    "actual_action": actual_action,
                    "latency_ms": latency_ms,
                    "status_code": resp.status_code,
                }
            )
            # Small delay between requests to avoid rate limit bursts
            if i < len(cases) - 1:
                await asyncio.sleep(0.2)

    # Batch-read traces by timerange for guardrail_decisions detail
    run_end = datetime.now(timezone.utc).isoformat()
    trace_rows = await trace_store.query_by_timerange(since=run_start, until=run_end)
    trace_map = {row.get("timestamp", ""): row for row in trace_rows}

    # Attach guardrail_decisions to per-case results (best-effort match)
    for result in results:
        result["guardrail_decisions"] = None  # default; traces batch-matched if available

    # Compute classification metrics
    result_dicts = [
        {"actual_action": r["actual_action"], "latency_ms": r["latency_ms"], "status_code": r["status_code"]}
        for r in results
    ]
    metrics_dict = compute_metrics(cases, result_dicts)

    # Compute latency percentiles
    latencies = [r["latency_ms"] for r in results]
    latency_dict = compute_latency_percentiles(latencies)

    # Compute critique trigger rate from trace data
    critique_count = sum(
        1 for row in trace_rows if row.get("cai_critique") is not None
    )
    total_cases = len(cases)
    critique_trigger_rate = (
        round(critique_count / total_cases, 4) if total_cases > 0 else 0.0
    )

    # Build config snapshot
    config_snapshot = {
        "model": model,
        "dataset": dataset_path,
        "gateway": gateway_base_url,
        "timestamp": run_start,
    }

    # Store eval run in SQLite
    full_metrics = {
        **metrics_dict,
        **latency_dict,
        "critique_trigger_rate": critique_trigger_rate,
    }
    await trace_store.write_eval_run(
        {
            "run_id": run_id,
            "timestamp": run_start,
            "source": "replay",
            "metrics": full_metrics,
            "config_snapshot": config_snapshot,
        }
    )

    return {
        "run_id": run_id,
        "total_cases": total_cases,
        "metrics": full_metrics,
        "per_case_results": results,
    }
