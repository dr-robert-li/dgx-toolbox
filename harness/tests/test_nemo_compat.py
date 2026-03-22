"""Smoke tests for NeMo Guardrails and Presidio aarch64 compatibility.

These tests validate that the libraries can be imported and function
correctly. They are designed to be skipped gracefully if the libraries
are not installed (e.g., in CI without aarch64 hardware).
"""
import pytest
from harness.guards.nemo_compat import check_nemo_available, check_presidio_available


def test_nemo_import():
    """NeMo Guardrails is importable (skip if not installed)."""
    result = check_nemo_available()
    if not result["available"]:
        pytest.skip(f"nemoguardrails not installed: {result['error']}")
    assert result["version"] is not None


def test_presidio_import():
    """Presidio analyzer is importable and detects entities."""
    result = check_presidio_available()
    if not result["available"]:
        pytest.skip(f"presidio not installed: {result['error']}")
    assert result["entities_detected"] >= 1


def test_check_nemo_returns_dict():
    """check_nemo_available always returns a dict with expected keys."""
    result = check_nemo_available()
    assert isinstance(result, dict)
    assert "available" in result
    assert "version" in result
    assert "error" in result


def test_check_presidio_returns_dict():
    """check_presidio_available always returns a dict with expected keys."""
    result = check_presidio_available()
    assert isinstance(result, dict)
    assert "available" in result
    assert "error" in result
