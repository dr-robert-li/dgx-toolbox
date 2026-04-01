"""UMA memory model for DGX Spark GB10 unified memory architecture.

Provides baseline sampling (with page cache drop) and headroom calculation
with jitter margin. UMA semantics: pin_memory is always False;
prefetch_factor is capped at 4.
"""
from __future__ import annotations

import logging
import time
from pathlib import Path

from telemetry.sampler import GPUSampler

logger = logging.getLogger(__name__)

_DROP_CACHES_PATH = Path("/proc/sys/vm/drop_caches")


class UMAMemModel:
    def __init__(self, sampler: GPUSampler):
        self._sampler = sampler

    def sample_baseline(self) -> dict:
        """Drop page cache (best-effort) then sample baseline memory state.

        Returns dict with keys: mem_available_gb, page_cache_gb,
        idle_watts, timestamp.

        If drop_caches fails (non-root), logs a warning that the baseline
        may include cached pages (dirty baseline). Addresses review concern:
        callers should know when baseline is not clean.
        """
        # Best-effort cache drop — requires root
        try:
            _DROP_CACHES_PATH.write_text("3")
        except (PermissionError, OSError) as exc:
            logger.warning(
                "Could not drop page cache (%s) — baseline may include "
                "cached pages (dirty baseline). Run as root for a clean "
                "baseline.",
                exc,
            )

        snapshot = self._sampler.sample()
        return {
            "mem_available_gb": snapshot["mem_available_gb"],
            "page_cache_gb": snapshot["page_cache_gb"],
            "idle_watts": snapshot["watts"],
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }

    @staticmethod
    def calculate_headroom(
        baseline: dict,
        current: dict,
        tier_headroom_pct: float,
        jitter_margin_gb: float = 5.0,
    ) -> dict:
        """Calculate safe memory threshold and headroom.

        safe_threshold = baseline_mem * (tier_headroom_pct/100) + jitter_margin_gb
        headroom_gb = current_mem - safe_threshold
        headroom_pct = headroom_gb / current_mem * 100  (0 if current_mem == 0)

        UMA semantics: pin_memory always False, prefetch_factor capped at 4.
        """
        baseline_mem = baseline.get("mem_available_gb", 0.0)
        current_mem = current.get("mem_available_gb", 0.0)
        safe_threshold = baseline_mem * (tier_headroom_pct / 100.0) + jitter_margin_gb
        headroom_gb = current_mem - safe_threshold
        headroom_pct = (headroom_gb / current_mem * 100.0) if current_mem > 0 else 0.0
        return {
            "safe_threshold": round(safe_threshold, 2),
            "headroom_gb": round(headroom_gb, 2),
            "headroom_pct": round(headroom_pct, 2),
            "pin_memory": False,
            "prefetch_factor": 4,  # Capped at 4 for UMA
        }
