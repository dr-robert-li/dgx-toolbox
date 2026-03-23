"""Dataset balance enforcement for red team adversarial datasets."""
from __future__ import annotations

import json
from collections import Counter
from pathlib import Path


def check_balance(
    pending_path: Path,
    active_dataset_dir: Path,
    max_category_ratio: float = 0.40,
) -> tuple[bool, dict[str, float]]:
    """Check if adding pending entries would violate category balance.

    Args:
        pending_path: Path to pending JSONL file.
        active_dataset_dir: Directory containing active *.jsonl datasets.
        max_category_ratio: Maximum fraction any single category may occupy.

    Returns:
        (ok, violations) where violations maps category -> actual ratio for violators.
    """
    counts: Counter = Counter()

    # Count categories in existing active datasets
    for f in active_dataset_dir.glob("*.jsonl"):
        for line in f.read_text().splitlines():
            if line.strip():
                counts[json.loads(line).get("category", "unknown")] += 1

    # Count categories in pending file
    pending_text = pending_path.read_text() if pending_path.exists() else ""
    pending_lines = [line for line in pending_text.splitlines() if line.strip()]
    if not pending_lines:
        return True, {}

    for line in pending_lines:
        counts[json.loads(line).get("category", "unknown")] += 1

    total = sum(counts.values())
    if total == 0:
        return True, {}

    violations = {
        cat: round(count / total, 4)
        for cat, count in counts.items()
        if count / total > max_category_ratio
    }
    return len(violations) == 0, violations
