"""CLI entry point: python -m harness.eval gate|replay|trends"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys


def main():
    parser = argparse.ArgumentParser(
        prog="python -m harness.eval",
        description="DGX harness eval tools: gate, replay, trends",
    )
    subparsers = parser.add_subparsers(dest="command")

    # --- gate subcommand ---
    gate_parser = subparsers.add_parser("gate", help="Run CI gate evaluation")
    gate_parser.add_argument("--tolerance", type=float, default=0.02,
                             help="Safety metric tolerance (default: 0.02)")
    gate_parser.add_argument("--capability-tolerance", type=float, default=0.05,
                             help="Capability metric tolerance (default: 0.05)")
    gate_parser.add_argument("--baseline", default=None,
                             help="Baseline name to compare against")
    gate_parser.add_argument("--dataset", default="harness/eval/datasets/safety-core.jsonl",
                             help="Path to eval dataset JSONL file")
    gate_parser.add_argument("--gateway", default="http://localhost:5000",
                             help="Gateway base URL (default: http://localhost:5000)")
    gate_parser.add_argument("--api-key", default=None,
                             help="API key (or set HARNESS_API_KEY env var)")
    gate_parser.add_argument("--db", default=None,
                             help="Path to traces.db")

    # --- replay subcommand ---
    replay_parser = subparsers.add_parser("replay", help="Run replay evaluation")
    replay_parser.add_argument("--dataset", required=True,
                               help="Path to eval dataset JSONL file")
    replay_parser.add_argument("--gateway", default="http://localhost:5000",
                               help="Gateway base URL")
    replay_parser.add_argument("--api-key", default=None,
                               help="API key (or set HARNESS_API_KEY env var)")
    replay_parser.add_argument("--model", default="Qwen/Qwen3.5-2B",
                               help="Model identifier (default: Qwen/Qwen3.5-2B)")
    replay_parser.add_argument("--db", default=None,
                               help="Path to traces.db")

    # --- trends subcommand ---
    trends_parser = subparsers.add_parser("trends", help="Show eval trend charts")
    trends_parser.add_argument("--last", type=int, default=20,
                               help="Number of recent runs to show (default: 20)")
    trends_parser.add_argument("--json", action="store_true",
                               help="Output as JSON instead of ASCII chart")
    trends_parser.add_argument("--source", default=None,
                               help="Filter by source (replay or lm-eval)")
    trends_parser.add_argument("--db", default=None,
                               help="Path to traces.db")

    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        sys.exit(1)

    if args.command == "gate":
        asyncio.run(_run_gate(args))

    elif args.command == "replay":
        asyncio.run(_run_replay(args))

    elif args.command == "trends":
        asyncio.run(_run_trends(args))


def _resolve_api_key(args) -> str:
    """Resolve API key from args or environment."""
    api_key = getattr(args, "api_key", None) or os.environ.get("HARNESS_API_KEY")
    if not api_key:
        print("Error: API key required. Use --api-key or set HARNESS_API_KEY env var.", file=sys.stderr)
        sys.exit(1)
    return api_key


def _resolve_db_path(args) -> str:
    """Resolve database path from args or environment."""
    if getattr(args, "db", None):
        return args.db
    data_dir = os.environ.get("HARNESS_DATA_DIR", "harness/data")
    return os.path.join(data_dir, "traces.db")


async def _run_gate(args):
    from harness.eval.gate import run_gate

    api_key = _resolve_api_key(args)
    db_path = _resolve_db_path(args)

    result = await run_gate(
        dataset_path=args.dataset,
        gateway_base_url=args.gateway,
        api_key=api_key,
        db_path=db_path,
        safety_tolerance=args.tolerance,
        capability_tolerance=args.capability_tolerance,
        baseline_name=args.baseline,
    )
    sys.exit(result)


async def _run_replay(args):
    from harness.eval.replay import run_replay
    from harness.traces.store import TraceStore

    api_key = _resolve_api_key(args)
    db_path = _resolve_db_path(args)

    trace_store = TraceStore(db_path=db_path)
    await trace_store.init_db()

    result = await run_replay(
        dataset_path=args.dataset,
        gateway_base_url=args.gateway,
        api_key=api_key,
        trace_store=trace_store,
        model=args.model,
    )

    m = result["metrics"]
    error_cases = m.get("error_cases", 0)
    scored_cases = result["total_cases"] - error_cases
    print(f"Run ID:       {result['run_id']}")
    print(f"Total cases:  {result['total_cases']}")
    print(f"Scored:       {scored_cases}  (errors/skipped: {error_cases})")
    print(f"F1:           {m.get('f1', 0.0):.4f}")
    print(f"Precision:    {m.get('precision', 0.0):.4f}")
    print(f"Recall:       {m.get('recall', 0.0):.4f}")
    print(f"CRR:          {m.get('correct_refusal_rate', 0.0):.4f}")
    print(f"FRR:          {m.get('false_refusal_rate', 0.0):.4f}")
    print(f"P50 latency:  {m.get('p50', 0)} ms")
    print(f"P95 latency:  {m.get('p95', 0)} ms")
    if error_cases > 0:
        print(f"\nWARNING: {error_cases} case(s) had transport errors (429 exhausted, 404, 5xx)")
        print("         and were excluded from metrics. Check harness gateway and backend.")


async def _run_trends(args):
    from harness.eval.trends import get_trend_data, render_trends, export_trends_json
    from harness.traces.store import TraceStore

    db_path = _resolve_db_path(args)

    trace_store = TraceStore(db_path=db_path)
    await trace_store.init_db()

    runs = await get_trend_data(trace_store, last=args.last, source=args.source)

    if args.json:
        print(json.dumps(export_trends_json(runs), indent=2))
    else:
        print(render_trends(runs))


if __name__ == "__main__":
    main()
