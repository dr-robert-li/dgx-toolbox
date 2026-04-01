"""Probe protocol for testing new training configurations.

prepare_probe() writes rollback and probe configs; the consuming project
runs 3-5 training steps and writes telemetry to results_path.
evaluate_probe() reads results and returns commit/revert recommendation.

Commit requires headroom_gb > 0 (strictly positive). Equal-to-threshold
reverts because zero headroom provides no safety margin.
"""
from __future__ import annotations

import json
from pathlib import Path

from telemetry.uma_model import UMAMemModel


def prepare_probe(
    current_config: dict,
    proposed_changes: dict,
    probe_dir: Path | None = None,
) -> dict:
    """Write rollback and probe configs for a configuration test.

    Args:
        current_config: The current training config dict.
        proposed_changes: Dict of config keys to change for the probe.
        probe_dir: Directory for probe files (default: /tmp/telemetry_probe).

    Returns:
        {"rollback_config_path": Path, "probe_config_path": Path, "results_path": Path}
    """
    if probe_dir is None:
        probe_dir = Path("/tmp/telemetry_probe")
    probe_dir = Path(probe_dir)
    probe_dir.mkdir(parents=True, exist_ok=True)

    rollback_path = probe_dir / "rollback_config.json"
    probe_path = probe_dir / "probe_config.json"
    results_path = probe_dir / "probe_results.jsonl"

    # Write rollback (original config)
    rollback_path.write_text(json.dumps(current_config, indent=2), encoding="utf-8")

    # Write probe (merged config: current overridden by proposed_changes)
    probe_config = {**current_config, **proposed_changes}
    probe_path.write_text(json.dumps(probe_config, indent=2), encoding="utf-8")

    # Ensure results file exists (empty, ready for training step writes)
    if not results_path.exists():
        results_path.touch()

    return {
        "rollback_config_path": rollback_path,
        "probe_config_path": probe_path,
        "results_path": results_path,
    }


def evaluate_probe(
    results_path: Path,
    baseline: dict,
    tier_headroom_pct: float,
    jitter_margin_gb: float = 5.0,
) -> dict:
    """Evaluate probe results and recommend commit or revert.

    Reads the results JSONL file, finds the minimum mem_available_gb
    (peak memory usage = minimum available), compares against the
    safe threshold from calculate_headroom.

    Commit requires headroom_gb > 0 (strictly positive). Equal-to-threshold
    reverts because zero headroom provides no safety margin.

    Args:
        results_path: Path to the JSONL file with probe telemetry records.
        baseline: Baseline dict with "mem_available_gb" key.
        tier_headroom_pct: Percentage of baseline memory to reserve as threshold.
        jitter_margin_gb: Additional GB margin for jitter (default: 5.0).

    Returns:
        {"action": "commit"|"revert", "reason": str, "anchor_record": dict|None}
    """
    results_path = Path(results_path)
    lines = results_path.read_text(encoding="utf-8").strip().splitlines()
    if not lines:
        return {
            "action": "revert",
            "reason": "No probe results recorded",
            "anchor_record": None,
        }

    readings = [json.loads(line) for line in lines if line.strip()]
    if not readings:
        return {
            "action": "revert",
            "reason": "No probe results recorded",
            "anchor_record": None,
        }

    # Peak memory usage = minimum available memory during probe
    min_mem = min(r.get("mem_available_gb", 0.0) for r in readings)

    # Calculate headroom at peak usage point
    headroom = UMAMemModel.calculate_headroom(
        baseline=baseline,
        current={"mem_available_gb": min_mem},
        tier_headroom_pct=tier_headroom_pct,
        jitter_margin_gb=jitter_margin_gb,
    )

    # Strictly positive headroom required to commit (>0, not >=0)
    if headroom["headroom_gb"] > 0:
        return {
            "action": "commit",
            "reason": (
                f"Peak memory OK: {headroom['headroom_gb']:.1f} GB headroom remaining"
            ),
            "anchor_record": {
                "status": "COMPLETED",
                "peak_mem_available_gb": min_mem,
                "headroom_gb": headroom["headroom_gb"],
                "safe_threshold": headroom["safe_threshold"],
            },
        }
    else:
        return {
            "action": "revert",
            "reason": (
                f"Peak memory exceeded safe threshold: "
                f"{min_mem:.1f} GB available < {headroom['safe_threshold']:.1f} GB needed"
            ),
            "anchor_record": None,
        }
