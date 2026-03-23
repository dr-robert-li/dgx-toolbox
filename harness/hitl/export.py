"""JSONL export: write reviewer corrections as OpenAI fine-tuning format."""
from __future__ import annotations

import json


async def export_jsonl(trace_store, output_path: str) -> int:
    """Export corrections as OpenAI-format JSONL for fine-tuning pipelines.

    For each correction, fetches the associated trace and writes a JSONL record:
    - prompt from trace["prompt"]
    - response:
        - If action == "edit": use correction["edited_response"]
        - Elif trace has non-null cai_critique: use cai_critique["revised_output"]
        - Else: use trace["response"]
    - label: correction["action"] (approve / reject / edit)

    Args:
        trace_store: TraceStore instance (must have query_corrections and query_by_id).
        output_path: File path to write JSONL output.

    Returns:
        Count of records written.
    """
    corrections = await trace_store.query_corrections()
    count = 0

    with open(output_path, "w", encoding="utf-8") as f:
        for correction in corrections:
            request_id = correction["request_id"]
            trace = await trace_store.query_by_id(request_id)
            if trace is None:
                continue

            record = _correction_to_jsonl_record(correction, trace)
            f.write(json.dumps(record) + "\n")
            count += 1

    return count


def _correction_to_jsonl_record(correction: dict, trace: dict) -> dict:
    """Convert a correction + trace pair to an OpenAI JSONL record.

    Args:
        correction: Correction dict (from corrections table).
        trace: Trace dict (from traces table).

    Returns:
        Dict with "messages" list and "label" field.
    """
    prompt = trace["prompt"]
    action = correction["action"]

    if action == "edit":
        # Use the edited response (already PII-redacted in store)
        response = correction.get("edited_response") or trace["response"]
    else:
        # Try cai_critique revised_output first
        cai_raw = trace.get("cai_critique")
        if cai_raw is not None:
            try:
                cai = json.loads(cai_raw) if isinstance(cai_raw, str) else cai_raw
                response = cai.get("revised_output", trace["response"])
            except (json.JSONDecodeError, TypeError, AttributeError):
                response = trace["response"]
        else:
            response = trace["response"]

    return {
        "messages": [
            {"role": "user", "content": prompt},
            {"role": "assistant", "content": response},
        ],
        "label": action,
    }
