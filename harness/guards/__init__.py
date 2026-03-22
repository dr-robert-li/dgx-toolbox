"""
harness.guards — NeMo Guardrails compatibility layer and guardrail engine.

Phase 5: Validates that nemoguardrails can be imported and that Presidio
is functional on aarch64.

Phase 6: GuardrailEngine with check_input/check_output, injection regex,
PII detection, and three refusal modes (hard_block, soft_steer, informative).
"""

from harness.guards.nemo_compat import check_nemo_available, check_presidio_available
from harness.guards.engine import GuardrailEngine, create_guardrail_engine

__all__ = [
    "check_nemo_available",
    "check_presidio_available",
    "GuardrailEngine",
    "create_guardrail_engine",
]
