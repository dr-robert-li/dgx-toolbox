"""Tests for constitution config loader — CSTL-02.

Covers Pydantic validation, YAML loading, and error handling for constitution.yaml.
"""
from __future__ import annotations

import os
from pathlib import Path

import pytest
import yaml


def test_load_valid_constitution(tmp_path):
    """load_constitution on valid YAML returns ConstitutionConfig with principles list."""
    from harness.critique.constitution import load_constitution

    data = {
        "constitution": {
            "judge_model": "default",
            "principles": [
                {
                    "id": "P-SAFETY-01",
                    "text": "Do not produce content that instructs harm.",
                    "category": "safety",
                    "priority": 1.0,
                    "enabled": True,
                },
                {
                    "id": "P-FAIRNESS-01",
                    "text": "Treat all groups equitably.",
                    "category": "fairness",
                    "priority": 0.85,
                    "enabled": True,
                },
            ],
        }
    }
    config_file = tmp_path / "constitution.yaml"
    config_file.write_text(yaml.dump(data))

    config = load_constitution(str(config_file))
    assert config.judge_model == "default"
    assert len(config.principles) == 2
    assert config.principles[0].id == "P-SAFETY-01"


def test_malformed_constitution_raises(tmp_path):
    """load_constitution on YAML missing required 'principles' key raises ValueError."""
    from harness.critique.constitution import load_constitution

    data = {"constitution": {"judge_model": "default"}}
    config_file = tmp_path / "bad.yaml"
    config_file.write_text(yaml.dump(data))

    with pytest.raises(ValueError):
        load_constitution(str(config_file))


def test_empty_constitution_raises(tmp_path):
    """Empty YAML file raises ValueError."""
    from harness.critique.constitution import load_constitution

    config_file = tmp_path / "empty.yaml"
    config_file.write_text("")

    with pytest.raises(ValueError):
        load_constitution(str(config_file))


def test_invalid_principle_raises(tmp_path):
    """Principle with missing 'text' field raises ValueError during load."""
    from harness.critique.constitution import load_constitution

    data = {
        "constitution": {
            "judge_model": "default",
            "principles": [
                {
                    "id": "P-SAFETY-01",
                    # text is missing
                    "category": "safety",
                    "priority": 1.0,
                },
            ],
        }
    }
    config_file = tmp_path / "invalid.yaml"
    config_file.write_text(yaml.dump(data))

    with pytest.raises(ValueError):
        load_constitution(str(config_file))


def test_disabled_principle_excluded(tmp_path):
    """ConstitutionConfig with 3 principles (2 enabled, 1 disabled); filtering returns 2."""
    from harness.critique.constitution import load_constitution

    data = {
        "constitution": {
            "judge_model": "default",
            "principles": [
                {
                    "id": "P-SAFETY-01",
                    "text": "Do not instruct harm.",
                    "category": "safety",
                    "priority": 1.0,
                    "enabled": True,
                },
                {
                    "id": "P-SAFETY-02",
                    "text": "Do not exploit minors.",
                    "category": "safety",
                    "priority": 0.95,
                    "enabled": True,
                },
                {
                    "id": "P-HELPFULNESS-01",
                    "text": "Offer safe alternatives.",
                    "category": "helpfulness",
                    "priority": 0.60,
                    "enabled": False,
                },
            ],
        }
    }
    config_file = tmp_path / "mixed.yaml"
    config_file.write_text(yaml.dump(data))

    config = load_constitution(str(config_file))
    active = [p for p in config.principles if p.enabled]
    assert len(active) == 2
    assert all(p.enabled for p in active)


def test_principle_priority_ordering(tmp_path):
    """Principles can be sorted by priority descending (highest first)."""
    from harness.critique.constitution import load_constitution

    data = {
        "constitution": {
            "judge_model": "default",
            "principles": [
                {
                    "id": "P-HELP-01",
                    "text": "Be helpful.",
                    "category": "helpfulness",
                    "priority": 0.55,
                    "enabled": True,
                },
                {
                    "id": "P-SAFETY-01",
                    "text": "Do not harm.",
                    "category": "safety",
                    "priority": 1.0,
                    "enabled": True,
                },
                {
                    "id": "P-FAIR-01",
                    "text": "Be fair.",
                    "category": "fairness",
                    "priority": 0.85,
                    "enabled": True,
                },
            ],
        }
    }
    config_file = tmp_path / "priorities.yaml"
    config_file.write_text(yaml.dump(data))

    config = load_constitution(str(config_file))
    sorted_principles = sorted(config.principles, key=lambda p: p.priority, reverse=True)
    assert sorted_principles[0].priority == 1.0
    assert sorted_principles[-1].priority == 0.55


def test_judge_model_configurable(tmp_path):
    """constitution.yaml with judge_model='llama3.1-70b' loads correctly."""
    from harness.critique.constitution import load_constitution

    data = {
        "constitution": {
            "judge_model": "llama3.1-70b",
            "principles": [
                {
                    "id": "P-SAFETY-01",
                    "text": "Do not instruct harm.",
                    "category": "safety",
                    "priority": 1.0,
                    "enabled": True,
                },
            ],
        }
    }
    config_file = tmp_path / "custom_model.yaml"
    config_file.write_text(yaml.dump(data))

    config = load_constitution(str(config_file))
    assert config.judge_model == "llama3.1-70b"


def test_default_constitution_loads():
    """The shipped harness/config/constitution.yaml loads without error and has >= 8 principles."""
    from harness.critique.constitution import load_constitution

    config_path = Path(__file__).parent.parent / "config" / "constitution.yaml"
    config = load_constitution(str(config_path))
    assert len(config.principles) >= 8
