"""Tests for ProbeProtocol: prepare_probe() and evaluate_probe() (TELEM-11, TELEM-12)."""

import json
import pytest
from pathlib import Path


def test_prepare_probe(tmp_path):
    """prepare_probe returns dict with rollback_config_path, probe_config_path, results_path; all exist."""
    from telemetry.probe import prepare_probe

    current_config = {"batch_size": 8, "lr": 1e-4, "model": "llama-7b"}
    proposed_changes = {"batch_size": 16}
    probe_dir = tmp_path / "probe"

    result = prepare_probe(current_config, proposed_changes, probe_dir=probe_dir)

    assert "rollback_config_path" in result
    assert "probe_config_path" in result
    assert "results_path" in result

    assert result["rollback_config_path"].exists(), "rollback config must exist on disk"
    assert result["probe_config_path"].exists(), "probe config must exist on disk"
    assert result["results_path"].exists(), "results path must exist on disk"


def test_prepare_probe_rollback_content(tmp_path):
    """The rollback config file contains the original current_config as JSON."""
    from telemetry.probe import prepare_probe

    current_config = {"batch_size": 8, "lr": 1e-4, "model": "llama-7b"}
    proposed_changes = {"batch_size": 16}
    probe_dir = tmp_path / "probe"

    result = prepare_probe(current_config, proposed_changes, probe_dir=probe_dir)

    rollback_data = json.loads(result["rollback_config_path"].read_text())
    assert rollback_data == current_config, (
        f"rollback config must equal current_config, got: {rollback_data}"
    )


def test_prepare_probe_probe_content(tmp_path):
    """The probe config merges proposed_changes into current_config."""
    from telemetry.probe import prepare_probe

    current_config = {"batch_size": 8, "lr": 1e-4, "model": "llama-7b"}
    proposed_changes = {"batch_size": 16}
    probe_dir = tmp_path / "probe"

    result = prepare_probe(current_config, proposed_changes, probe_dir=probe_dir)

    probe_data = json.loads(result["probe_config_path"].read_text())
    expected = {"batch_size": 16, "lr": 1e-4, "model": "llama-7b"}
    assert probe_data == expected, (
        f"probe config must be merged, got: {probe_data}"
    )


def test_evaluate_probe_commit(tmp_path):
    """evaluate_probe with peak_mem > safe_threshold returns action='commit' with anchor_record."""
    from telemetry.probe import evaluate_probe

    results_path = tmp_path / "results.jsonl"
    # Write probe results: minimum mem_available = 60.0 GB
    results_path.write_text(
        json.dumps({"mem_available_gb": 60.0}) + "\n" +
        json.dumps({"mem_available_gb": 65.0}) + "\n"
    )

    # baseline=80.0 GB, tier_headroom_pct=20, jitter=5.0 → safe_threshold = 80*0.2+5=21.0
    # headroom_gb = 60.0 - 21.0 = 39.0 > 0 → commit
    result = evaluate_probe(
        results_path=results_path,
        baseline={"mem_available_gb": 80.0},
        tier_headroom_pct=20,
        jitter_margin_gb=5.0,
    )

    assert result["action"] == "commit", f"Expected 'commit', got {result['action']!r}"
    assert result["anchor_record"] is not None, "commit result must have anchor_record"


def test_evaluate_probe_revert(tmp_path):
    """evaluate_probe with peak_mem < safe_threshold returns action='revert'."""
    from telemetry.probe import evaluate_probe

    results_path = tmp_path / "results.jsonl"
    # Minimum mem_available = 15.0 GB (very low)
    results_path.write_text(
        json.dumps({"mem_available_gb": 15.0}) + "\n" +
        json.dumps({"mem_available_gb": 20.0}) + "\n"
    )

    # baseline=80.0 GB, tier_headroom_pct=20, jitter=5.0 → safe_threshold = 21.0
    # headroom_gb = 15.0 - 21.0 = -6.0 <= 0 → revert
    result = evaluate_probe(
        results_path=results_path,
        baseline={"mem_available_gb": 80.0},
        tier_headroom_pct=20,
        jitter_margin_gb=5.0,
    )

    assert result["action"] == "revert", f"Expected 'revert', got {result['action']!r}"
    assert "reason" in result


def test_evaluate_probe_equal_threshold_commits(tmp_path):
    """evaluate_probe with peak_mem == safe_threshold (headroom_gb == 0) returns 'revert'."""
    from telemetry.probe import evaluate_probe

    results_path = tmp_path / "results.jsonl"
    # safe_threshold = 80.0 * 0.20 + 5.0 = 21.0
    # Set min_mem = exactly 21.0 → headroom_gb = 0 → revert (strictly > 0 required)
    results_path.write_text(
        json.dumps({"mem_available_gb": 21.0}) + "\n"
    )

    result = evaluate_probe(
        results_path=results_path,
        baseline={"mem_available_gb": 80.0},
        tier_headroom_pct=20,
        jitter_margin_gb=5.0,
    )

    assert result["action"] == "revert", (
        f"Exact threshold (headroom=0) must revert, got: {result['action']!r}"
    )


def test_evaluate_probe_anchor_record(tmp_path):
    """commit result anchor_record contains status, peak_mem_available_gb, headroom_gb, safe_threshold."""
    from telemetry.probe import evaluate_probe

    results_path = tmp_path / "results.jsonl"
    results_path.write_text(json.dumps({"mem_available_gb": 60.0}) + "\n")

    result = evaluate_probe(
        results_path=results_path,
        baseline={"mem_available_gb": 80.0},
        tier_headroom_pct=20,
        jitter_margin_gb=5.0,
    )

    assert result["action"] == "commit"
    record = result["anchor_record"]
    assert "status" in record, "anchor_record must have 'status'"
    assert "peak_mem_available_gb" in record, "anchor_record must have 'peak_mem_available_gb'"
    assert "headroom_gb" in record, "anchor_record must have 'headroom_gb'"
    assert "safe_threshold" in record, "anchor_record must have 'safe_threshold'"
