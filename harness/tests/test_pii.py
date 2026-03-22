"""Tests for PII redactor — covers TRAC-03 (PII redacted before trace write)."""
import pytest
import spacy.util


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_HAS_SPACY_MODEL = spacy.util.is_package("en_core_web_lg")


def _skip_without_model():
    if not _HAS_SPACY_MODEL:
        pytest.skip("en_core_web_lg not installed — skipping spaCy-dependent test")


# ---------------------------------------------------------------------------
# Tests for structured PII (email, phone, SSN, credit card) — regex layer
# ---------------------------------------------------------------------------

def test_redact_email():
    from harness.pii.redactor import redact
    result = redact("Contact john@example.com", strictness="minimal")
    assert "[EMAIL]" in result
    assert "john@example.com" not in result


def test_redact_phone():
    from harness.pii.redactor import redact
    result = redact("Call 555-123-4567", strictness="minimal")
    assert "[PHONE]" in result
    assert "555-123-4567" not in result


def test_redact_ssn():
    from harness.pii.redactor import redact
    result = redact("SSN 123-45-6789", strictness="minimal")
    assert "[SSN]" in result
    assert "123-45-6789" not in result


def test_redact_credit_card():
    from harness.pii.redactor import redact
    result = redact("Card 4111111111111111", strictness="minimal")
    assert "[CREDIT_CARD]" in result
    assert "4111111111111111" not in result


def test_no_pii_unchanged():
    from harness.pii.redactor import redact
    result = redact("Hello world", strictness="minimal")
    assert result == "Hello world"


def test_redact_strict_mode():
    """Strict mode detects names and dates (spaCy NER required)."""
    _skip_without_model()
    from harness.pii.redactor import redact
    # Strict mode should catch structured PII at minimum
    result = redact("john@example.com", strictness="strict")
    assert "[EMAIL]" in result


def test_redact_minimal_mode():
    """Minimal mode catches only structured PII — not names."""
    from harness.pii.redactor import redact
    # Minimal handles structured PII via regex
    result = redact("Email: user@test.com SSN 123-45-6789", strictness="minimal")
    assert "[EMAIL]" in result
    assert "[SSN]" in result
    assert "user@test.com" not in result
    assert "123-45-6789" not in result
