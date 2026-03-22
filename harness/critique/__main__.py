"""CLI entry point: python -m harness.critique analyze --since 24h"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys


def main():
    parser = argparse.ArgumentParser(description="Constitutional AI critique tools")
    subparsers = parser.add_subparsers(dest="command")

    analyze_parser = subparsers.add_parser("analyze", help="Analyze trace history for tuning suggestions")
    analyze_parser.add_argument("--since", default="24h", help="Time window: ISO8601 or shorthand (24h, 7d)")
    analyze_parser.add_argument("--min-samples", type=int, default=10, help="Minimum critique records required")
    analyze_parser.add_argument("--db", default=None, help="Path to traces.db (default: harness/data/traces.db)")
    analyze_parser.add_argument("--config-dir", default=None, help="Path to config dir (default: harness/config)")

    args = parser.parse_args()
    if args.command is None:
        parser.print_help()
        sys.exit(1)

    if args.command == "analyze":
        asyncio.run(_run_analyze(args))


async def _run_analyze(args):
    from harness.critique.analyzer import analyze_traces
    from harness.critique.constitution import load_constitution
    from harness.traces.store import TraceStore
    from harness.proxy.admin import _resolve_since
    import httpx

    config_dir = args.config_dir or os.path.join(os.path.dirname(os.path.dirname(__file__)), "config")
    db_path = args.db or os.path.join(os.path.dirname(os.path.dirname(__file__)), "data", "traces.db")

    constitution = load_constitution(os.path.join(config_dir, "constitution.yaml"))
    trace_store = TraceStore(db_path=db_path)

    litellm_base = os.environ.get("LITELLM_BASE_URL", "http://localhost:4000")
    async with httpx.AsyncClient(base_url=litellm_base, timeout=httpx.Timeout(120.0)) as http_client:
        since_ts = _resolve_since(args.since)
        result = await analyze_traces(
            trace_store=trace_store,
            http_client=http_client,
            constitution=constitution,
            since=since_ts,
        )

    print(result["report"])
    if result["yaml_diffs"]:
        print("\n### Machine-Readable Diffs (YAML)\n")
        print(json.dumps(result["yaml_diffs"], indent=2))


if __name__ == "__main__":
    main()
