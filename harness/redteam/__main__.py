"""CLI entry point: python -m harness.redteam [promote|list]"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

from harness.redteam.balance import check_balance

ACTIVE_DIR = Path(__file__).parent.parent / "eval" / "datasets"
PENDING_DIR = ACTIVE_DIR / "pending"


def cmd_promote(args):
    """Promote a pending adversarial dataset to active after balance check."""
    pending_file = Path(args.file)
    if not pending_file.exists():
        print(f"ERROR: File not found: {pending_file}", file=sys.stderr)
        sys.exit(1)

    max_ratio = args.max_ratio

    ok, violations = check_balance(pending_file, ACTIVE_DIR, max_ratio)
    if not ok:
        print(f"ERROR: Balance check failed. Categories exceed {max_ratio*100:.0f}% cap:", file=sys.stderr)
        for cat, ratio in sorted(violations.items(), key=lambda x: -x[1]):
            print(f"  {cat}: {ratio*100:.1f}%", file=sys.stderr)
        sys.exit(1)

    dest = ACTIVE_DIR / pending_file.name
    shutil.move(str(pending_file), str(dest))
    print(f"Promoted: {dest}")

    # Show summary
    count = sum(1 for line in dest.read_text().splitlines() if line.strip())
    print(f"  Entries: {count}")


def cmd_list(args):
    """List pending adversarial datasets."""
    if not PENDING_DIR.exists():
        print("No pending directory found.")
        return
    files = sorted(PENDING_DIR.glob("*.jsonl"))
    if not files:
        print("No pending datasets.")
        return
    for f in files:
        count = sum(1 for line in f.read_text().splitlines() if line.strip())
        print(f"  {f.name}  ({count} entries)")


def main():
    parser = argparse.ArgumentParser(
        prog="python -m harness.redteam",
        description="Red team dataset management",
    )
    sub = parser.add_subparsers(dest="command")

    p_promote = sub.add_parser("promote", help="Promote pending dataset to active after balance check")
    p_promote.add_argument("file", help="Path to pending JSONL file")
    p_promote.add_argument(
        "--max-ratio",
        type=float,
        default=0.40,
        help="Max category ratio (default 0.40)",
    )

    sub.add_parser("list", help="List pending adversarial datasets")

    args = parser.parse_args()
    if args.command == "promote":
        cmd_promote(args)
    elif args.command == "list":
        cmd_list(args)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
