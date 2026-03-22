"""
harness.guards — NeMo Guardrails compatibility layer.

Phase 5: Validates that nemoguardrails can be imported and that Presidio
is functional on aarch64. Phase 6+ will add actual guardrail logic here.
"""

from harness.guards.nemo_compat import check_nemo_available, check_presidio_available

__all__ = ["check_nemo_available", "check_presidio_available"]
