"""CLI entry point: python -m harness.hitl calibrate|export|ui"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys


def main():
    parser = argparse.ArgumentParser(
        prog="python -m harness.hitl",
        description="DGX harness HITL tools: calibrate, export, ui",
    )
    subparsers = parser.add_subparsers(dest="command")

    # --- calibrate ---
    cal = subparsers.add_parser("calibrate", help="Compute threshold suggestions from corrections")
    cal.add_argument("--db", default=None, help="Path to traces.db")
    cal.add_argument("--since", default="7d", help="Time window for corrections (default: 7d)")

    # --- export ---
    exp = subparsers.add_parser("export", help="Export corrections as fine-tuning JSONL")
    exp.add_argument("--format", choices=["jsonl"], default="jsonl", help="Output format")
    exp.add_argument("--output", default="corrections.jsonl", help="Output file path")
    exp.add_argument("--db", default=None, help="Path to traces.db")

    # --- ui ---
    ui_p = subparsers.add_parser("ui", help="Start Gradio review UI")
    ui_p.add_argument("--port", type=int, default=8501, help="Gradio port")
    ui_p.add_argument("--api-url", default="http://localhost:8080", help="Harness API URL")
    ui_p.add_argument("--api-key", default=None, help="API key (or HARNESS_API_KEY env)")

    args = parser.parse_args()
    if args.command is None:
        parser.print_help()
        sys.exit(1)
    elif args.command == "calibrate":
        asyncio.run(_run_calibrate(args))
    elif args.command == "export":
        asyncio.run(_run_export(args))
    elif args.command == "ui":
        _run_ui(args)


def _resolve_db_path(args) -> str:
    if getattr(args, "db", None):
        return args.db
    data_dir = os.environ.get("HARNESS_DATA_DIR", "harness/data")
    return os.path.join(data_dir, "traces.db")


async def _run_calibrate(args):
    from harness.hitl.calibrate import compute_calibration
    from harness.traces.store import TraceStore
    from harness.proxy.admin import _resolve_since

    db_path = _resolve_db_path(args)
    store = TraceStore(db_path=db_path)
    await store.init_db()
    since_ts = _resolve_since(args.since)
    suggestions = await compute_calibration(store, since=since_ts)
    if not suggestions:
        print("No suggestions — insufficient correction data (minimum 5 per rail).")
        return
    for s in suggestions:
        print(f"Rail: {s['rail']}")
        print(f"  Current:   {s['current_threshold']:.3f}")
        print(f"  Suggested: {s['suggested_threshold']:.3f}")
        print(f"  Approved:  {s['approved_count']}  Rejected: {s['rejected_count']}")
        print(f"  Reason:    {s['reason']}")
        print()


async def _run_export(args):
    from harness.hitl.export import export_jsonl
    from harness.traces.store import TraceStore

    db_path = _resolve_db_path(args)
    store = TraceStore(db_path=db_path)
    await store.init_db()
    count = await export_jsonl(store, output_path=args.output)
    print(f"Exported {count} corrections to {args.output}")


def _run_ui(args):
    try:
        from harness.hitl.ui import build_ui
    except ImportError:
        print("Error: gradio not installed. Install with: pip install 'dgx-harness[hitl]'", file=sys.stderr)
        sys.exit(1)
    api_key = args.api_key or os.environ.get("HARNESS_API_KEY")
    if not api_key:
        print("Error: API key required. Use --api-key or set HARNESS_API_KEY env var.", file=sys.stderr)
        sys.exit(1)
    demo = build_ui(api_url=args.api_url, api_key=api_key)
    demo.launch(server_port=args.port)


if __name__ == "__main__":
    main()
