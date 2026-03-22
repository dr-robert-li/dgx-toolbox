"""Type contracts for the guardrail engine.

GuardrailDecision and RailResult are the typed data contracts shared between
the normalizer, rail runners (Plan 02), and the gateway response handler.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional


@dataclass
class RailResult:
    """Result from a single rail classifier run."""

    rail: str         # Rail name from rails.yaml (e.g. "self_check_input")
    result: str       # "pass" | "block"
    score: float      # Classifier confidence 0.0-1.0
    threshold: float  # Configured threshold from rails.yaml


@dataclass
class GuardrailDecision:
    """Aggregated guardrail decision after all rails have run."""

    blocked: bool
    refusal_mode: Optional[str]         # "hard_block" | "soft_steer" | "informative" | None
    triggering_rail: Optional[str]      # Name of first blocking rail (for refusal message)
    all_results: list[RailResult]       # Every rail that ran (pass + block)
    replacement_response: Optional[dict] = None  # Populated for output blocks / soft steer
    evasion_flags: list[str] = field(default_factory=list)  # From normalizer
