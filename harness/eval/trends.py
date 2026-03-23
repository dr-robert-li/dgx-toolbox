"""Trend report generation for eval run history.

Provides ASCII chart visualization and JSON export of eval run metrics
for tracking improvements and regressions over time.
"""
from __future__ import annotations

from harness.traces.store import TraceStore


async def get_trend_data(
    trace_store: TraceStore,
    last: int = 20,
    source: str | None = None,
) -> list[dict]:
    """Fetch eval run trend data in chronological order.

    Args:
        trace_store: Initialized TraceStore instance.
        last: Maximum number of runs to return.
        source: Optional source filter ("replay" or "lm-eval").

    Returns:
        List of eval run dicts ordered oldest-first (chronological).
    """
    runs = await trace_store.query_eval_runs(source=source, limit=last)
    # query_eval_runs returns DESC; reverse to chronological for charts
    return list(reversed(runs))


def render_trends(runs: list[dict]) -> str:
    """Render ASCII trend charts for key metrics.

    Args:
        runs: List of eval run dicts (chronological order).

    Returns:
        Multi-line string with ASCII charts and a summary table.
    """
    if not runs:
        return "No eval runs found."

    # Extract metric series
    f1_series = [r["metrics"].get("f1", 0.0) for r in runs]
    crr_series = [r["metrics"].get("correct_refusal_rate", 0.0) for r in runs]
    frr_series = [r["metrics"].get("false_refusal_rate", 0.0) for r in runs]

    lines: list[str] = []

    # Try asciichartpy; fall back to simple text table
    try:
        import asciichartpy

        def _chart(series: list[float], title: str) -> str:
            chart_lines = [f"== {title} =="]
            if len(series) >= 2:
                chart_lines.append(asciichartpy.plot(series, {"height": 10}))
            else:
                chart_lines.append(f"  {series[0]:.4f}" if series else "  (no data)")
            return "\n".join(chart_lines)

        lines.append(_chart(f1_series, "F1 Score"))
        lines.append("")
        lines.append(_chart(crr_series, "Correct Refusal Rate"))
        lines.append("")
        lines.append(_chart(frr_series, "False Refusal Rate"))

    except ImportError:
        # Fallback: simple text representation
        lines.append("== F1 Score ==")
        lines.extend(f"  {v:.4f}" for v in f1_series)
        lines.append("")
        lines.append("== Correct Refusal Rate ==")
        lines.extend(f"  {v:.4f}" for v in crr_series)
        lines.append("")
        lines.append("== False Refusal Rate ==")
        lines.extend(f"  {v:.4f}" for v in frr_series)

    lines.append("")

    # Direction arrows: compare last two values
    def _direction(series: list[float]) -> str:
        if len(series) < 2:
            return "STABLE"
        delta = series[-1] - series[-2]
        if delta > 0.001:
            return "UP"
        elif delta < -0.001:
            return "DOWN"
        return "STABLE"

    f1_dir = _direction(f1_series)
    crr_dir = _direction(crr_series)
    frr_dir = _direction(frr_series)

    lines.append(f"Trend (last run): F1={f1_dir}  CRR={crr_dir}  FRR={frr_dir}")
    lines.append("")

    # Summary table
    lines.append(f"Run History (last {len(runs)}):")
    lines.append(f"{'Run ID':<20} {'Timestamp':<25} {'Source':<8} {'F1':>6} {'Refusal':>8} {'False Ref':>9}")
    lines.append("-" * 80)
    for run in runs:
        m = run["metrics"]
        lines.append(
            f"{run['run_id'][:20]:<20} {run['timestamp'][:25]:<25} "
            f"{run.get('source', '')[:8]:<8} "
            f"{m.get('f1', 0.0):>6.4f} "
            f"{m.get('correct_refusal_rate', 0.0):>8.4f} "
            f"{m.get('false_refusal_rate', 0.0):>9.4f}"
        )

    return "\n".join(lines)


def export_trends_json(runs: list[dict]) -> list[dict]:
    """Export eval run history as machine-readable JSON.

    Format is consumed by Phase 10 HITL dashboard.

    Args:
        runs: List of eval run dicts.

    Returns:
        List of dicts with keys: run_id, timestamp, source, metrics.
    """
    return [
        {
            "run_id": run["run_id"],
            "timestamp": run["timestamp"],
            "source": run.get("source", ""),
            "metrics": run["metrics"],
        }
        for run in runs
    ]
