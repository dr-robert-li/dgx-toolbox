"""PII redaction using regex pre-pass + Microsoft Presidio NER.

The regex layer handles structured PII (emails, SSNs, phone numbers, credit cards)
reliably even when the spaCy model is unavailable.  Presidio NER then catches
unstructured PII (names, addresses, dates) that regex cannot match.
"""
from __future__ import annotations

import re

from presidio_analyzer import AnalyzerEngine
from presidio_anonymizer import AnonymizerEngine
from presidio_anonymizer.entities import OperatorConfig

# ---------------------------------------------------------------------------
# Module-level Presidio initialization — loaded once at import time
# ---------------------------------------------------------------------------
_analyzer = AnalyzerEngine()
_anonymizer = AnonymizerEngine()

# ---------------------------------------------------------------------------
# Entity lists per strictness level
# ---------------------------------------------------------------------------
STRICTNESS_ENTITIES: dict[str, list[str]] = {
    "strict": [
        "PERSON",
        "EMAIL_ADDRESS",
        "PHONE_NUMBER",
        "US_SSN",
        "CREDIT_CARD",
        "LOCATION",
        "DATE_TIME",
        "IP_ADDRESS",
        "MEDICAL_LICENSE",
        "URL",
        "IBAN_CODE",
        "NRP",
    ],
    "balanced": [
        "PERSON",
        "EMAIL_ADDRESS",
        "PHONE_NUMBER",
        "US_SSN",
        "CREDIT_CARD",
        "LOCATION",
    ],
    "minimal": [
        "EMAIL_ADDRESS",
        "PHONE_NUMBER",
        "US_SSN",
        "CREDIT_CARD",
    ],
}

# ---------------------------------------------------------------------------
# Operator map — entity type -> replacement token
# ---------------------------------------------------------------------------
_OPERATOR_MAP: dict[str, OperatorConfig] = {
    "PERSON": OperatorConfig("replace", {"new_value": "[NAME]"}),
    "EMAIL_ADDRESS": OperatorConfig("replace", {"new_value": "[EMAIL]"}),
    "PHONE_NUMBER": OperatorConfig("replace", {"new_value": "[PHONE]"}),
    "US_SSN": OperatorConfig("replace", {"new_value": "[SSN]"}),
    "CREDIT_CARD": OperatorConfig("replace", {"new_value": "[CREDIT_CARD]"}),
    "LOCATION": OperatorConfig("replace", {"new_value": "[ADDRESS]"}),
    "DEFAULT": OperatorConfig("replace", {"new_value": "[REDACTED]"}),
}

# ---------------------------------------------------------------------------
# Regex patterns for structured PII — run BEFORE Presidio as a safety net
# ---------------------------------------------------------------------------
# Order matters: more specific patterns first
_REGEX_PATTERNS: list[tuple[re.Pattern, str]] = [
    # Email addresses
    (
        re.compile(r"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}", re.IGNORECASE),
        "[EMAIL]",
    ),
    # US SSN: NNN-NN-NNNN
    (
        re.compile(r"\b\d{3}-\d{2}-\d{4}\b"),
        "[SSN]",
    ),
    # Credit card: 13-16 digit runs (optionally space/dash separated)
    (
        re.compile(r"\b(?:\d[ \-]?){13,16}\b"),
        "[CREDIT_CARD]",
    ),
    # US phone numbers: various formats
    (
        re.compile(
            r"\b(?:\+?1[-.\s]?)?(?:\(\d{3}\)|\d{3})[-.\s]?\d{3}[-.\s]?\d{4}\b"
        ),
        "[PHONE]",
    ),
]


def _regex_redact(text: str) -> str:
    """Apply regex patterns for structured PII replacement."""
    for pattern, replacement in _REGEX_PATTERNS:
        text = pattern.sub(replacement, text)
    return text


def redact(text: str, strictness: str = "balanced") -> str:
    """Redact PII from text using a regex pre-pass and Presidio NER.

    Args:
        text: Input text, potentially containing PII.
        strictness: One of "strict", "balanced", or "minimal".
                    Controls which Presidio entity types are detected.

    Returns:
        Text with PII replaced by typed tokens such as [EMAIL], [PHONE],
        [SSN], [CREDIT_CARD], [NAME], [ADDRESS], [REDACTED].
    """
    # Step 1: Regex pre-pass — catches structured PII regardless of spaCy model
    text = _regex_redact(text)

    # Step 2: Presidio NER pass — catches unstructured PII (names, addresses, etc.)
    entities = STRICTNESS_ENTITIES.get(strictness, STRICTNESS_ENTITIES["balanced"])
    results = _analyzer.analyze(text=text, entities=entities, language="en")

    if not results:
        return text

    anonymized = _anonymizer.anonymize(
        text=text,
        analyzer_results=results,
        operators=_OPERATOR_MAP,
    )
    return anonymized.text
