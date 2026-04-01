"""AnchorStore: JSON-persistent configuration anchor records.

Stores proven training configuration records keyed by SHA-256 config hash.
Records expire after 7 days. Uses atomic write-to-temp-then-rename to prevent
corruption on interrupted writes.

Override rules (TELEM-10):
  COMPLETED  → raises ceiling: batch_cap = max(tier_cap, batch_size + step_size)
  OOM        → hard cap: batch_cap = batch_size - step_size
  WATCHDOG   → hard cap: batch_cap = batch_size - step_size
  HANG       → logs only: NO batch_cap key (TELEM-14)
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
from datetime import datetime, timezone, timedelta
from pathlib import Path

logger = logging.getLogger(__name__)

# PERMANENT COMPATIBILITY CONTRACT — field list and order are locked forever.
# Changing this list breaks all existing anchor records.
# SHA-256 of these 9 fields concatenated with "|" separator.
HASH_FIELDS = [
    "model_id", "quant_mode", "framework", "grad_ckpt",
    "lora_rank", "seq_len", "optimizer", "batch_size", "grad_accum",
]

EXPIRY_DAYS = 7


class AnchorStore:
    """Persistent store for proven training configuration anchors.

    Args:
        store_path: Path to the JSON store file. Created on first write.
    """

    def __init__(self, store_path: Path) -> None:
        self._store_path = Path(store_path)
        self._records: dict = self._load()

    def compute_config_hash(self, config: dict) -> str:
        """Compute SHA-256 hash of the 9 locked HASH_FIELDS in the config.

        Fields are concatenated in HASH_FIELDS order with "|" separator.
        Missing fields are represented as empty strings.

        Args:
            config: Training configuration dict.

        Returns:
            SHA-256 hex digest string.
        """
        values = [str(config.get(field, "")) for field in HASH_FIELDS]
        raw = "|".join(values)
        return hashlib.sha256(raw.encode("utf-8")).hexdigest()

    def lookup(self, config_hash: str) -> dict | None:
        """Return record by config_hash if exists and not expired; None otherwise.

        Expired records are purged from the in-memory store on access but NOT
        immediately persisted (lazy purge to avoid unnecessary disk writes).

        Args:
            config_hash: SHA-256 hex digest identifying the config.

        Returns:
            Record dict or None if not found or expired.
        """
        record = self._records.get(config_hash)
        if record is None:
            return None
        if self._is_expired(record):
            del self._records[config_hash]
            return None
        return record

    def apply_override(
        self,
        config_hash: str,
        status: str,
        batch_size: int,
        tier_cap: int,
        step_size: int = 2,
    ) -> dict:
        """Create or replace the anchor record for a config hash.

        Single-record-per-hash: writing to an existing config_hash REPLACES
        the previous record (newest write wins — not accumulation).

        Override rules (TELEM-10):
            COMPLETED → batch_cap = max(tier_cap, batch_size + step_size)
            OOM       → batch_cap = batch_size - step_size
            WATCHDOG  → batch_cap = batch_size - step_size
            HANG      → NO batch_cap key (TELEM-14)

        Args:
            config_hash: SHA-256 hex digest identifying the config.
            status: One of COMPLETED, OOM, WATCHDOG, HANG.
            batch_size: Current batch size observed.
            tier_cap: Tier-level maximum batch cap.
            step_size: Step increment/decrement for cap calculation.

        Returns:
            The written record dict.
        """
        record: dict = {
            "status": status,
            "created_at": datetime.now(timezone.utc).isoformat(),
        }

        if status == "COMPLETED":
            record["batch_cap"] = max(tier_cap, batch_size + step_size)
        elif status in ("OOM", "WATCHDOG"):
            record["batch_cap"] = batch_size - step_size
        # HANG: intentionally no batch_cap key (TELEM-14)

        # Single-record-per-hash: replace previous record
        self._records[config_hash] = record
        self._save()
        return record

    def _load(self) -> dict:
        """Load records from JSON file. Returns empty dict on any failure."""
        try:
            content = self._store_path.read_text(encoding="utf-8")
            return json.loads(content)
        except FileNotFoundError:
            return {}
        except json.JSONDecodeError as exc:
            logger.warning(
                "AnchorStore: corrupted JSON at %s (%s) — starting with empty store.",
                self._store_path,
                exc,
            )
            return {}

    def _save(self) -> None:
        """Atomic write using write-to-temp-then-rename pattern.

        Writes to a temporary file in the same directory, then renames
        to the final path. Ensures the store file is never partially written
        if the process is interrupted.
        """
        self._store_path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = self._store_path.with_suffix(".tmp")
        tmp_path.write_text(
            json.dumps(self._records, indent=2, default=str),
            encoding="utf-8",
        )
        os.replace(tmp_path, self._store_path)

    def _is_expired(self, record: dict) -> bool:
        """Return True if the record's created_at is older than EXPIRY_DAYS from now (UTC)."""
        created_at_str = record.get("created_at")
        if not created_at_str:
            return False
        try:
            created_at = datetime.fromisoformat(created_at_str)
            # Ensure timezone-aware comparison
            if created_at.tzinfo is None:
                created_at = created_at.replace(tzinfo=timezone.utc)
            now = datetime.now(timezone.utc)
            return (now - created_at) > timedelta(days=EXPIRY_DAYS)
        except (ValueError, TypeError):
            return False
