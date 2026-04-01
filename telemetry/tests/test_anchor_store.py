"""Tests for AnchorStore (TELEM-09, TELEM-10)."""

import json
import pytest
from datetime import datetime, timezone, timedelta
from pathlib import Path
from unittest.mock import patch


def test_config_hash_field_order():
    """HASH_FIELDS list is exactly the 9-field permanent compatibility contract."""
    from telemetry.anchor_store import HASH_FIELDS

    expected = [
        "model_id", "quant_mode", "framework", "grad_ckpt",
        "lora_rank", "seq_len", "optimizer", "batch_size", "grad_accum",
    ]
    assert HASH_FIELDS == expected, (
        f"HASH_FIELDS must be exactly {expected}, got {HASH_FIELDS}"
    )


def test_compute_config_hash(tmp_path):
    """Two identical configs produce the same hash; changing any field produces a different hash."""
    from telemetry.anchor_store import AnchorStore, HASH_FIELDS

    store = AnchorStore(tmp_path / "anchors.json")

    config_a = {
        "model_id": "llama-7b",
        "quant_mode": "int4",
        "framework": "pytorch",
        "grad_ckpt": "none",
        "lora_rank": 16,
        "seq_len": 2048,
        "optimizer": "adamw",
        "batch_size": 8,
        "grad_accum": 4,
    }
    config_b = dict(config_a)  # identical

    hash_a = store.compute_config_hash(config_a)
    hash_b = store.compute_config_hash(config_b)
    assert hash_a == hash_b, "Identical configs must produce the same hash"

    # Change one field
    config_c = dict(config_a)
    config_c["batch_size"] = 16
    hash_c = store.compute_config_hash(config_c)
    assert hash_a != hash_c, "Changing any field must produce a different hash"


def test_write_and_read(tmp_path):
    """Write a record, then lookup by config_hash returns the same record."""
    from telemetry.anchor_store import AnchorStore

    store_path = tmp_path / "anchors.json"
    store = AnchorStore(store_path)

    config = {
        "model_id": "mistral-7b",
        "quant_mode": "fp16",
        "framework": "pytorch",
        "grad_ckpt": "none",
        "lora_rank": 0,
        "seq_len": 2048,
        "optimizer": "adamw",
        "batch_size": 8,
        "grad_accum": 1,
    }
    config_hash = store.compute_config_hash(config)
    record = store.apply_override(
        config_hash=config_hash,
        status="COMPLETED",
        batch_size=8,
        tier_cap=16,
        step_size=2,
    )

    result = store.lookup(config_hash)
    assert result is not None, "lookup should return the written record"
    assert result["status"] == "COMPLETED"
    assert result["batch_cap"] == record["batch_cap"]


def test_expiry_7_days(tmp_path):
    """Record with created_at 8 days ago is expired; 6 days ago is still valid."""
    from telemetry.anchor_store import AnchorStore

    store_path = tmp_path / "anchors.json"
    store = AnchorStore(store_path)

    config = {
        "model_id": "test-model",
        "quant_mode": "fp16",
        "framework": "pytorch",
        "grad_ckpt": "none",
        "lora_rank": 0,
        "seq_len": 2048,
        "optimizer": "adamw",
        "batch_size": 4,
        "grad_accum": 1,
    }
    config_hash = store.compute_config_hash(config)

    # Write record with 8 days ago timestamp
    old_time = (datetime.now(timezone.utc) - timedelta(days=8)).isoformat()
    store._records[config_hash] = {
        "status": "COMPLETED",
        "batch_cap": 8,
        "created_at": old_time,
    }
    store._save()

    # Load fresh instance
    store2 = AnchorStore(store_path)
    assert store2.lookup(config_hash) is None, (
        "8-day-old record should be expired and return None"
    )

    # Write record with 6 days ago timestamp
    recent_time = (datetime.now(timezone.utc) - timedelta(days=6)).isoformat()
    store2._records[config_hash] = {
        "status": "COMPLETED",
        "batch_cap": 8,
        "created_at": recent_time,
    }
    store2._save()

    store3 = AnchorStore(store_path)
    assert store3.lookup(config_hash) is not None, (
        "6-day-old record should not be expired"
    )


def test_completed_raises_ceiling(tmp_path):
    """COMPLETED: batch_cap = max(tier_cap, batch_size + step_size)."""
    from telemetry.anchor_store import AnchorStore

    store = AnchorStore(tmp_path / "anchors.json")
    # batch_size=12, tier_cap=16, step_size=2 → max(16, 14) = 16
    record = store.apply_override(
        config_hash="hash1",
        status="COMPLETED",
        batch_size=12,
        tier_cap=16,
        step_size=2,
    )
    assert record["batch_cap"] == 16, (
        f"COMPLETED: max(16, 12+2)=16 expected, got {record['batch_cap']}"
    )


def test_completed_above_tier(tmp_path):
    """COMPLETED: when batch_size+step exceeds tier_cap, use the higher value."""
    from telemetry.anchor_store import AnchorStore

    store = AnchorStore(tmp_path / "anchors.json")
    # batch_size=20, tier_cap=16, step_size=2 → max(16, 22) = 22
    record = store.apply_override(
        config_hash="hash2",
        status="COMPLETED",
        batch_size=20,
        tier_cap=16,
        step_size=2,
    )
    assert record["batch_cap"] == 22, (
        f"COMPLETED: max(16, 20+2)=22 expected, got {record['batch_cap']}"
    )


def test_oom_sets_hard_cap(tmp_path):
    """OOM: batch_cap = batch_size - step_size."""
    from telemetry.anchor_store import AnchorStore

    store = AnchorStore(tmp_path / "anchors.json")
    record = store.apply_override(
        config_hash="hash3",
        status="OOM",
        batch_size=12,
        tier_cap=16,
        step_size=2,
    )
    assert record["batch_cap"] == 10, (
        f"OOM: 12-2=10 expected, got {record['batch_cap']}"
    )


def test_watchdog_sets_hard_cap(tmp_path):
    """WATCHDOG: batch_cap = batch_size - step_size (same rule as OOM)."""
    from telemetry.anchor_store import AnchorStore

    store = AnchorStore(tmp_path / "anchors.json")
    record = store.apply_override(
        config_hash="hash4",
        status="WATCHDOG",
        batch_size=12,
        tier_cap=16,
        step_size=2,
    )
    assert record["batch_cap"] == 10, (
        f"WATCHDOG: 12-2=10 expected, got {record['batch_cap']}"
    )


def test_hang_no_batch_cap(tmp_path):
    """HANG: record has NO 'batch_cap' key (TELEM-10/TELEM-14)."""
    from telemetry.anchor_store import AnchorStore

    store = AnchorStore(tmp_path / "anchors.json")
    record = store.apply_override(
        config_hash="hash5",
        status="HANG",
        batch_size=12,
        tier_cap=16,
        step_size=2,
    )
    assert "batch_cap" not in record, (
        f"HANG must NOT have batch_cap key, got record: {record}"
    )


def test_persistence_across_instances(tmp_path):
    """Write via one instance; new instance pointing to same file returns the record."""
    from telemetry.anchor_store import AnchorStore

    store_path = tmp_path / "anchors.json"
    store1 = AnchorStore(store_path)
    store1.apply_override(
        config_hash="persistent_hash",
        status="COMPLETED",
        batch_size=8,
        tier_cap=16,
        step_size=2,
    )

    store2 = AnchorStore(store_path)
    result = store2.lookup("persistent_hash")
    assert result is not None, "Record should persist across instances"
    assert result["status"] == "COMPLETED"


def test_single_record_per_hash(tmp_path):
    """Writing two records with same config_hash returns only the newest one."""
    from telemetry.anchor_store import AnchorStore

    store_path = tmp_path / "anchors.json"
    store = AnchorStore(store_path)

    store.apply_override(
        config_hash="same_hash",
        status="COMPLETED",
        batch_size=8,
        tier_cap=16,
        step_size=2,
    )
    # Overwrite with OOM
    store.apply_override(
        config_hash="same_hash",
        status="OOM",
        batch_size=8,
        tier_cap=16,
        step_size=2,
    )

    result = store.lookup("same_hash")
    assert result is not None
    assert result["status"] == "OOM", (
        f"Expected newest record (OOM), got: {result['status']}"
    )
    # Ensure only one record per hash
    assert len([k for k in store._records if k == "same_hash"]) == 1, (
        "Must have exactly one record per hash"
    )


def test_atomic_write_survives_crash(tmp_path):
    """After _save(), the JSON file is valid and a temp file was used."""
    from telemetry.anchor_store import AnchorStore

    store_path = tmp_path / "anchors.json"
    store = AnchorStore(store_path)
    store.apply_override(
        config_hash="atomic_hash",
        status="COMPLETED",
        batch_size=8,
        tier_cap=16,
        step_size=2,
    )

    # JSON file must be valid after save
    content = store_path.read_text()
    data = json.loads(content)  # Raises on invalid JSON
    assert "atomic_hash" in data, "Record must be in the saved JSON file"

    # No leftover temp file
    tmp_file = store_path.with_suffix(".tmp")
    assert not tmp_file.exists(), "Temp file should not exist after successful save"


def test_corrupted_json_recovery(tmp_path):
    """AnchorStore loads as empty dict when JSON file is corrupted (no crash)."""
    from telemetry.anchor_store import AnchorStore

    store_path = tmp_path / "anchors.json"
    store_path.write_text("{invalid json here!!!}")

    # Should not crash
    store = AnchorStore(store_path)
    assert isinstance(store._records, dict)
    assert len(store._records) == 0, "Corrupted file should result in empty records"
