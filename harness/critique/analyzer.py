"""Tuning analysis system for Constitutional AI critique pipeline.

Reads historical critique data from SQLite, calls a judge model to identify
patterns, and produces ranked threshold + principle tuning suggestions with
both human-readable and machine-readable output.
"""
from __future__ import annotations

import json
from collections import Counter
from datetime import datetime, timezone
from typing import Any

from harness.critique.constitution import ConstitutionConfig
from harness.traces.store import TraceStore

MIN_SAMPLE_SIZE = 10


async def analyze_traces(
    trace_store: TraceStore,
    http_client: Any,
    constitution: ConstitutionConfig,
    since: str,
    judge_model: str = "default",
) -> dict:
    """Analyze historical critique traces and produce tuning suggestions.

    Args:
        trace_store: Async SQLite-backed trace storage.
        http_client: Async HTTP client (httpx.AsyncClient or compatible mock).
        constitution: Loaded ConstitutionConfig (provides judge_model + principles).
        since: ISO8601 lower-bound timestamp for the analysis window.
        judge_model: Override for judge model name; "default" falls back to
                     constitution.judge_model, then "unknown".

    Returns:
        dict with keys:
            "report"       — human-readable markdown (str)
            "yaml_diffs"   — machine-readable list of suggestion dicts
            "generated_at" — ISO8601 timestamp string
    """
    generated_at = datetime.now(timezone.utc).isoformat()

    # --- 1. Query traces in time range ------------------------------------
    rows = await trace_store.query_by_timerange(since=since)

    # Filter to rows that have a non-null cai_critique and parse JSON
    critique_rows: list[dict] = []
    for row in rows:
        raw = row.get("cai_critique")
        if raw is None:
            continue
        if isinstance(raw, str):
            try:
                critique = json.loads(raw)
            except json.JSONDecodeError:
                continue
        elif isinstance(raw, dict):
            critique = raw
        else:
            continue
        critique_rows.append(critique)

    # --- 2. Minimum sample size guard ------------------------------------
    if len(critique_rows) < MIN_SAMPLE_SIZE:
        n = len(critique_rows)
        return {
            "report": (
                f"## Tuning Suggestions\n\n"
                f"Insufficient data: found {n} critique records "
                f"(minimum: {MIN_SAMPLE_SIZE}). "
                f"Run more requests through the critique pipeline before analyzing."
            ),
            "yaml_diffs": [],
            "generated_at": generated_at,
        }

    # --- 3. Aggregate patterns -------------------------------------------
    per_rail_triggers: Counter = Counter()
    per_principle_violations: Counter = Counter()
    outcome_counts: Counter = Counter()
    confidence_values: list[float] = []
    # per-rail score stats: { rail: {"original": [], "revision": []} }
    threshold_stats: dict[str, dict[str, list[float]]] = {}

    for c in critique_rows:
        # triggered_by
        triggered_by = c.get("triggered_by", "unknown")
        per_rail_triggers[triggered_by] += 1

        # violated principles
        judge_resp = c.get("judge_response") or {}
        for pid in judge_resp.get("violated_principles") or []:
            per_principle_violations[pid] += 1

        # confidence
        conf = judge_resp.get("confidence")
        if conf is not None:
            confidence_values.append(float(conf))

        # outcome
        outcome = c.get("outcome", "unknown")
        outcome_counts[outcome] += 1

        # threshold stats per rail
        rail = triggered_by
        if rail not in threshold_stats:
            threshold_stats[rail] = {"original": [], "revision": []}
        orig_score = c.get("original_score")
        rev_score = c.get("revision_score")
        if orig_score is not None:
            threshold_stats[rail]["original"].append(float(orig_score))
        if rev_score is not None:
            threshold_stats[rail]["revision"].append(float(rev_score))

    avg_confidence = (
        sum(confidence_values) / len(confidence_values) if confidence_values else 0.0
    )

    # --- 4. Resolve judge model ------------------------------------------
    effective_judge = judge_model
    if effective_judge == "default":
        effective_judge = constitution.judge_model
    if effective_judge == "default":
        effective_judge = "unknown"

    # --- 5. Build analysis prompt ----------------------------------------
    system_prompt = (
        "You are a guardrail tuning advisor. Analyze the following aggregate data "
        "from a Constitutional AI critique pipeline and provide tuning suggestions. "
        "Respond ONLY with valid JSON matching the schema: "
        "{\"suggestions\": [{\"type\": \"threshold\"|\"principle\", ...fields...}], "
        "\"summary\": \"<markdown summary>\"}. "
        "For threshold suggestions include: rail, current, suggested, reason. "
        "For principle suggestions include: action (enable|disable|add), id, reason."
    )

    # Format aggregates as readable text for the user message
    rails_text = "\n".join(
        f"  - {rail}: {count} triggers"
        for rail, count in per_rail_triggers.most_common()
    )
    principles_text = "\n".join(
        f"  - {pid}: violated {count} times"
        for pid, count in per_principle_violations.most_common()
    )
    outcomes_text = "\n".join(
        f"  - {outcome}: {count}" for outcome, count in outcome_counts.most_common()
    )
    threshold_text_parts = []
    for rail, stats in threshold_stats.items():
        orig_scores = stats["original"]
        rev_scores = stats["revision"]
        mean_orig = sum(orig_scores) / len(orig_scores) if orig_scores else 0.0
        mean_rev = sum(rev_scores) / len(rev_scores) if rev_scores else 0.0
        threshold_text_parts.append(
            f"  - {rail}: mean_original_score={mean_orig:.3f}, mean_revision_score={mean_rev:.3f}"
        )
    threshold_text = "\n".join(threshold_text_parts)

    user_content = (
        f"Analysis window: since={since}\n"
        f"Total critique records: {len(critique_rows)}\n"
        f"Average judge confidence: {avg_confidence:.3f}\n\n"
        f"Per-rail trigger frequency:\n{rails_text or '  (none)'}\n\n"
        f"Per-principle violation frequency:\n{principles_text or '  (none)'}\n\n"
        f"Outcome distribution (revised vs fallback_hard_block):\n{outcomes_text or '  (none)'}\n\n"
        f"Threshold statistics per rail:\n{threshold_text or '  (none)'}\n\n"
        f"Please provide ranked tuning suggestions in the required JSON format."
    )

    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_content},
    ]

    # --- 6. Call judge model ---------------------------------------------
    try:
        response = await http_client.post(
            "/v1/chat/completions",
            json={"model": effective_judge, "messages": messages},
        )
        response_body = response.json()
        content = (
            response_body.get("choices", [{}])[0]
            .get("message", {})
            .get("content", "")
        )
        judge_data = json.loads(content)
    except (json.JSONDecodeError, KeyError, IndexError, Exception):
        return {
            "report": (
                "## Tuning Suggestions\n\n"
                "Analysis failed: could not parse judge model response."
            ),
            "yaml_diffs": [],
            "generated_at": generated_at,
        }

    # --- 7. Transform suggestions into yaml_diffs and markdown -----------
    suggestions = judge_data.get("suggestions") or []
    summary_text = judge_data.get("summary", "No summary provided.")

    yaml_diffs: list[dict] = []
    ranked_lines: list[str] = []

    for idx, suggestion in enumerate(suggestions, start=1):
        s_type = suggestion.get("type", "unknown")
        yaml_diffs.append(suggestion)

        if s_type == "threshold":
            rail = suggestion.get("rail", "?")
            current = suggestion.get("current", "?")
            suggested = suggestion.get("suggested", "?")
            reason = suggestion.get("reason", "")
            ranked_lines.append(
                f"{idx}. **Threshold adjustment** — rail `{rail}`: "
                f"{current} → {suggested}. _{reason}_"
            )
        elif s_type == "principle":
            action = suggestion.get("action", "?")
            pid = suggestion.get("id", "?")
            reason = suggestion.get("reason", "")
            ranked_lines.append(
                f"{idx}. **Principle {action}** — `{pid}`. _{reason}_"
            )
        else:
            ranked_lines.append(f"{idx}. **{s_type}**: {json.dumps(suggestion)}")

    ranked_text = "\n".join(ranked_lines) if ranked_lines else "_No suggestions generated._"

    report = (
        f"## Tuning Suggestions\n\n"
        f"{summary_text}\n\n"
        f"### Detailed Suggestions\n\n"
        f"{ranked_text}"
    )

    return {
        "report": report,
        "yaml_diffs": yaml_diffs,
        "generated_at": generated_at,
    }
