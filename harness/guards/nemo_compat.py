"""
NeMo Guardrails compatibility module.

Phase 5: Validates that nemoguardrails can be imported and LLMRails
can be instantiated at module level on aarch64.

Phase 6+: Will contain actual guardrail configuration and rail logic.

CRITICAL: LLMRails MUST be instantiated at module level, before
uvicorn.run() is called. NeMo Guardrails applies nest_asyncio on
import, which conflicts with uvicorn's event loop if initialization
happens inside a running async task.
(Source: https://github.com/NVIDIA/NeMo-Guardrails/issues/137)
"""

import importlib


def check_nemo_available() -> dict:
    """Check if NeMo Guardrails is importable and return version info."""
    result = {"available": False, "version": None, "error": None}
    try:
        nemo = importlib.import_module("nemoguardrails")
        result["available"] = True
        result["version"] = getattr(nemo, "__version__", "unknown")
    except ImportError as e:
        result["error"] = str(e)
    return result


def check_presidio_available() -> dict:
    """Check if Presidio analyzer is importable and functional."""
    result = {"available": False, "entities_detected": 0, "error": None}
    try:
        from presidio_analyzer import AnalyzerEngine
        engine = AnalyzerEngine()
        results = engine.analyze(
            text="test@example.com",
            language="en",
            entities=["EMAIL_ADDRESS"],
        )
        result["available"] = True
        result["entities_detected"] = len(results)
    except Exception as e:
        result["error"] = str(e)
    return result
