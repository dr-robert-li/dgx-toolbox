"""CLI entry point: python -m harness.hitl [ui|calibrate|export]"""
from __future__ import annotations

import argparse
import sys


def cmd_ui(args: argparse.Namespace) -> None:
    """Launch the Gradio HITL review dashboard."""
    try:
        import gradio  # noqa: F401
    except ImportError:
        print(
            "ERROR: gradio is not installed. "
            "Install with: pip install 'harness[hitl]'",
            file=sys.stderr,
        )
        sys.exit(1)

    from harness.hitl.ui import build_ui

    demo = build_ui(api_url=args.api_url, api_key=args.api_key)
    demo.launch(server_port=args.port, server_name="0.0.0.0", share=False)


def cmd_calibrate(args: argparse.Namespace) -> None:
    """Run threshold calibration from reviewer corrections."""
    try:
        from harness.hitl.calibrate import compute_calibration  # type: ignore[import]
    except ImportError:
        print("ERROR: calibrate module not available (run plan 02 first).", file=sys.stderr)
        sys.exit(1)
    import asyncio
    import os
    from harness.traces.store import TraceStore

    db_path = args.db or os.path.join(
        os.path.dirname(__file__), "..", "data", "traces.db"
    )
    store = TraceStore(db_path=db_path)
    results = asyncio.run(compute_calibration(store, since=args.since))
    if not results:
        print("Insufficient data — need more corrections per rail (minimum 5).")
    else:
        import json
        print(json.dumps(results, indent=2))


def cmd_export(args: argparse.Namespace) -> None:
    """Export reviewer corrections as OpenAI-format JSONL for fine-tuning."""
    try:
        from harness.hitl.export import export_jsonl  # type: ignore[import]
    except ImportError:
        print("ERROR: export module not available (run plan 02 first).", file=sys.stderr)
        sys.exit(1)
    import asyncio
    import os
    from harness.traces.store import TraceStore

    db_path = args.db or os.path.join(
        os.path.dirname(__file__), "..", "data", "traces.db"
    )
    store = TraceStore(db_path=db_path)
    asyncio.run(export_jsonl(store, output_path=args.output, since=args.since))
    print(f"Exported to {args.output}")


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="python -m harness.hitl",
        description="HITL dashboard tools: UI, calibration, and fine-tuning export",
    )
    sub = parser.add_subparsers(dest="command")

    # ui subcommand
    p_ui = sub.add_parser("ui", help="Launch Gradio HITL review dashboard")
    p_ui.add_argument(
        "--port", type=int, default=8501, help="Port to listen on (default 8501)"
    )
    p_ui.add_argument(
        "--api-url",
        default="http://localhost:8080",
        help="Harness API base URL (default http://localhost:8080)",
    )
    p_ui.add_argument(
        "--api-key",
        default="sk-test",
        help="Bearer token for harness API (default sk-test)",
    )

    # calibrate subcommand
    p_cal = sub.add_parser("calibrate", help="Compute threshold calibration suggestions")
    p_cal.add_argument("--db", default=None, help="Path to traces.db")
    p_cal.add_argument("--since", default="7d", help="Time window (default 7d)")

    # export subcommand
    p_exp = sub.add_parser("export", help="Export corrections as JSONL for fine-tuning")
    p_exp.add_argument("--output", required=True, help="Output JSONL file path")
    p_exp.add_argument("--db", default=None, help="Path to traces.db")
    p_exp.add_argument("--since", default="30d", help="Time window (default 30d)")

    args = parser.parse_args()

    if args.command == "ui":
        cmd_ui(args)
    elif args.command == "calibrate":
        cmd_calibrate(args)
    elif args.command == "export":
        cmd_export(args)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
