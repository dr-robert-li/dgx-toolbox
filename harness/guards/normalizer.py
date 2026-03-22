"""Unicode normalizer — first preprocessing step before every classifier.

Strips zero-width characters, applies NFKC normalization, and detects
homoglyphs. Returns evasion flags alongside the cleaned text so callers
can include them in GuardrailDecision.evasion_flags.
"""
from __future__ import annotations

import re
import unicodedata

from confusable_homoglyphs import confusables

# All Unicode zero-width and invisible characters to strip before classification.
_ZERO_WIDTH_PATTERN = re.compile(
    r"[\u200b\u200c\u200d\u200e\u200f\ufeff\u00ad\u2060\u2061\u2062\u2063\u2064]"
)


def normalize(text: str) -> tuple[str, list[str]]:
    """Normalize a single text string and return evasion flags.

    Steps applied in order:
    1. NFKC normalization — flags "unicode_normalization_changed" if text changed.
    2. Zero-width character stripping — flags "zero_width_chars_stripped" if any removed.
    3. Homoglyph detection — flags "homoglyph_detected" if confusable chars present.

    Args:
        text: Raw input string.

    Returns:
        Tuple of (cleaned_text, list_of_evasion_flags).
    """
    flags: list[str] = []

    # Step 1: NFKC normalization (converts full-width, ligatures, etc. to ASCII equivalents)
    nfkc = unicodedata.normalize("NFKC", text)
    if nfkc != text:
        flags.append("unicode_normalization_changed")

    # Step 2: Strip zero-width and invisible characters
    stripped = _ZERO_WIDTH_PATTERN.sub("", nfkc)
    if stripped != nfkc:
        flags.append("zero_width_chars_stripped")

    # Step 3: Homoglyph / confusable character detection
    # is_confusable returns a list of confusable char info or False
    confusable_result = confusables.is_confusable(stripped, preferred_aliases=["latin"])
    if confusable_result:
        flags.append("homoglyph_detected")

    return stripped, flags


def normalize_messages(messages: list[dict]) -> tuple[list[dict], list[str]]:
    """Normalize all 'content' fields in a messages list.

    Each message's 'content' field is normalized. Other fields are passed
    through unchanged. Messages without a 'content' field are left intact.

    Args:
        messages: List of chat message dicts (e.g. [{"role": "user", "content": "..."}]).

    Returns:
        Tuple of (normalized_messages, aggregated_flags).
    """
    all_flags: list[str] = []
    new_messages: list[dict] = []

    for msg in messages:
        if "content" in msg and isinstance(msg["content"], str):
            cleaned, flags = normalize(msg["content"])
            new_msg = {**msg, "content": cleaned}
            all_flags.extend(flags)
        else:
            new_msg = msg
        new_messages.append(new_msg)

    # Deduplicate flags while preserving order
    seen: set[str] = set()
    deduped: list[str] = []
    for f in all_flags:
        if f not in seen:
            seen.add(f)
            deduped.append(f)

    return new_messages, deduped
