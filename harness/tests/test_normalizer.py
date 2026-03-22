"""Tests for Unicode normalizer — INRL-01, REFU-04.

Covers zero-width stripping, NFKC normalization, and homoglyph detection.
"""
import pytest


def test_nfkc_normalization():
    """Full-width chars normalize to ASCII and flag is raised."""
    from harness.guards.normalizer import normalize
    text = "\uff28\uff45\uff4c\uff4c\uff4f"  # Full-width "Hello"
    result, flags = normalize(text)
    assert result == "Hello"
    assert "unicode_normalization_changed" in flags


def test_zero_width_stripped():
    """Zero-width chars are removed and flag is raised."""
    from harness.guards.normalizer import normalize
    result, flags = normalize("hel\u200blo")
    assert result == "hello"
    assert "zero_width_chars_stripped" in flags


def test_clean_text_no_flags():
    """Clean ASCII text returns unchanged with empty flags."""
    from harness.guards.normalizer import normalize
    result, flags = normalize("hello world")
    assert result == "hello world"
    assert flags == []


def test_homoglyph_flagged():
    """Cyrillic 'а' (U+0430) mixed with Latin triggers homoglyph_detected."""
    from harness.guards.normalizer import normalize
    # Cyrillic а (U+0430) looks like Latin a
    result, flags = normalize("p\u0430ssword")
    assert "homoglyph_detected" in flags


def test_normalize_messages():
    """Message list content fields are all normalized."""
    from harness.guards.normalizer import normalize_messages
    msgs = [{"role": "user", "content": "test\u200b"}]
    new_msgs, flags = normalize_messages(msgs)
    assert new_msgs[0]["content"] == "test"
    assert len(flags) > 0
    assert "zero_width_chars_stripped" in flags


def test_all_zero_width_chars_stripped():
    """Each zero-width character is individually stripped."""
    from harness.guards.normalizer import normalize
    zero_width_chars = [
        "\u200b",  # ZERO WIDTH SPACE
        "\u200c",  # ZERO WIDTH NON-JOINER
        "\u200d",  # ZERO WIDTH JOINER
        "\u200e",  # LEFT-TO-RIGHT MARK
        "\u200f",  # RIGHT-TO-LEFT MARK
        "\ufeff",  # ZERO WIDTH NO-BREAK SPACE (BOM)
        "\u00ad",  # SOFT HYPHEN
        "\u2060",  # WORD JOINER
        "\u2061",  # FUNCTION APPLICATION
        "\u2062",  # INVISIBLE TIMES
        "\u2063",  # INVISIBLE SEPARATOR
        "\u2064",  # INVISIBLE PLUS
    ]
    for char in zero_width_chars:
        result, flags = normalize(f"a{char}b")
        assert result == "ab", f"Expected 'ab' but got {result!r} for char U+{ord(char):04X}"
        assert "zero_width_chars_stripped" in flags, f"Missing flag for U+{ord(char):04X}"


def test_multiple_flags():
    """Input with both NFKC changes and zero-width chars gets both flags."""
    from harness.guards.normalizer import normalize
    # Full-width "H" (\uff28) + zero-width space + "ello"
    text = "\uff28\u200bello"
    result, flags = normalize(text)
    assert "unicode_normalization_changed" in flags
    assert "zero_width_chars_stripped" in flags


def test_normalize_messages_preserves_role():
    """normalize_messages preserves role and other fields untouched."""
    from harness.guards.normalizer import normalize_messages
    msgs = [
        {"role": "system", "content": "clean system"},
        {"role": "user", "content": "hello\u200bworld"},
    ]
    new_msgs, flags = normalize_messages(msgs)
    assert new_msgs[0]["role"] == "system"
    assert new_msgs[0]["content"] == "clean system"
    assert new_msgs[1]["content"] == "helloworld"
    assert "zero_width_chars_stripped" in flags


def test_normalize_messages_no_content_field():
    """Messages without 'content' field are passed through unchanged."""
    from harness.guards.normalizer import normalize_messages
    msgs = [{"role": "tool_call", "function": {"name": "foo"}}]
    new_msgs, flags = normalize_messages(msgs)
    assert new_msgs[0] == msgs[0]
    assert flags == []
