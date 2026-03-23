"""Calibration engine: compute per-rail threshold suggestions from reviewer corrections."""
from __future__ import annotations

import json

MIN_CORRECTIONS = 5


async def compute_calibration(trace_store, since: str) -> list[dict]:
    """Compute per-rail threshold suggestions from reviewer corrections.

    Groups corrections by triggering rail, then for each rail with >= MIN_CORRECTIONS
    corrections, computes a suggested threshold:
    - Both approved and rejected: midpoint between max(approved) and min(rejected).
    - Approved only: P95 of approved scores (sorted, index = int(0.95 * len)).
    - Rejected only: min(rejected) - 0.05 (lower threshold to catch more).

    Args:
        trace_store: TraceStore instance (must have query_corrections and query_by_id).
        since: ISO8601 timestamp string — lower bound for corrections to consider.

    Returns:
        List of suggestion dicts with keys:
            rail, current_threshold, suggested_threshold,
            approved_count, rejected_count, reason.
    """
    corrections = await trace_store.query_corrections()

    # Group corrections by triggering rail
    # Per correction, fetch the trace to get guardrail_decisions
    rail_data: dict[str, dict] = {}  # rail_name -> {approved: [], rejected: [], threshold: float}

    for correction in corrections:
        request_id = correction["request_id"]
        trace = await trace_store.query_by_id(request_id)
        if trace is None:
            continue

        gd_raw = trace.get("guardrail_decisions")
        if gd_raw is None:
            continue

        try:
            gd = json.loads(gd_raw) if isinstance(gd_raw, str) else gd_raw
        except (json.JSONDecodeError, TypeError):
            continue

        all_results = gd.get("all_results", [])
        if not all_results:
            continue

        # Find the triggering rail (closest to threshold — same logic as _extract_triggering_rail)
        best_result = None
        best_distance = float("inf")
        for result in all_results:
            score = result.get("score", 0)
            threshold = result.get("threshold", 1.0)
            if score > 0:
                distance = threshold - score
                if distance < best_distance:
                    best_distance = distance
                    best_result = result

        if best_result is None:
            continue

        rail_name = best_result.get("rail_name") or best_result.get("rail")
        if not rail_name:
            continue

        score = best_result.get("score", 0.0)
        threshold = best_result.get("threshold", 1.0)

        if rail_name not in rail_data:
            rail_data[rail_name] = {
                "approved": [],
                "rejected": [],
                "threshold": threshold,
            }

        action = correction["action"]
        if action in ("approve", "edit"):
            rail_data[rail_name]["approved"].append(score)
        elif action == "reject":
            rail_data[rail_name]["rejected"].append(score)

    # Compute suggestions for rails with >= MIN_CORRECTIONS
    suggestions = []
    for rail_name, data in rail_data.items():
        approved_scores = data["approved"]
        rejected_scores = data["rejected"]
        total = len(approved_scores) + len(rejected_scores)

        if total < MIN_CORRECTIONS:
            continue

        current_threshold = data["threshold"]

        if approved_scores and rejected_scores:
            # Both sets non-empty: midpoint
            suggested = (max(approved_scores) + min(rejected_scores)) / 2
            reason = (
                f"Midpoint between max approved score ({max(approved_scores):.3f}) "
                f"and min rejected score ({min(rejected_scores):.3f})"
            )
        elif approved_scores:
            # Approved only: P95
            sorted_scores = sorted(approved_scores)
            p95_idx = int(0.95 * len(sorted_scores))
            suggested = sorted_scores[p95_idx]
            reason = (
                f"P95 of {len(approved_scores)} approved scores "
                f"(no rejections available)"
            )
        else:
            # Rejected only: min - 0.05
            suggested = min(rejected_scores) - 0.05
            reason = (
                f"Below min rejected score ({min(rejected_scores):.3f}) "
                f"to catch more rejections"
            )

        suggestions.append({
            "rail": rail_name,
            "current_threshold": current_threshold,
            "suggested_threshold": suggested,
            "approved_count": len(approved_scores),
            "rejected_count": len(rejected_scores),
            "reason": reason,
        })

    return suggestions
