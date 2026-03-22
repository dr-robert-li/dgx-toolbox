"""Tests for rail config loader — INRL-05, OURL-04.

Covers Pydantic validation, YAML loading, and error handling for rails.yaml.
"""
import os
import tempfile

import pytest
import yaml


def test_load_rails_config_valid():
    """Loading the actual rails.yaml returns 7 RailConfig objects with correct values."""
    from harness.config.rail_loader import load_rails_config
    rails_path = os.path.join(
        os.path.dirname(__file__), "..", "config", "rails", "rails.yaml"
    )
    rails = load_rails_config(rails_path)
    assert len(rails) == 7
    first = rails[0]
    assert first.name == "self_check_input"
    assert first.threshold == 0.7
    assert first.enabled is True


def test_load_rails_config_invalid_mode():
    """YAML with an invalid refusal_mode raises ValueError."""
    from harness.config.rail_loader import load_rails_config
    bad_yaml = {"rails": [{"name": "test_rail", "refusal_mode": "bad"}]}
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".yaml", delete=False
    ) as f:
        yaml.dump(bad_yaml, f)
        temp_path = f.name
    try:
        with pytest.raises(ValueError):
            load_rails_config(temp_path)
    finally:
        os.unlink(temp_path)


def test_load_rails_config_empty_file():
    """Empty YAML file raises ValueError."""
    from harness.config.rail_loader import load_rails_config
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".yaml", delete=False
    ) as f:
        f.write("")
        temp_path = f.name
    try:
        with pytest.raises(ValueError):
            load_rails_config(temp_path)
    finally:
        os.unlink(temp_path)


def test_load_rails_config_missing_name():
    """Rail missing 'name' field raises ValueError."""
    from harness.config.rail_loader import load_rails_config
    bad_yaml = {"rails": [{"enabled": True, "threshold": 0.7, "refusal_mode": "hard_block"}]}
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".yaml", delete=False
    ) as f:
        yaml.dump(bad_yaml, f)
        temp_path = f.name
    try:
        with pytest.raises(ValueError):
            load_rails_config(temp_path)
    finally:
        os.unlink(temp_path)


def test_rail_config_defaults():
    """RailConfig with only name field uses expected defaults."""
    from harness.config.rail_loader import RailConfig
    rc = RailConfig(name="test_rail")
    assert rc.enabled is True
    assert rc.threshold == 0.7
    assert rc.refusal_mode == "hard_block"


def test_load_rails_config_all_modes():
    """All three valid refusal_mode values load correctly."""
    from harness.config.rail_loader import load_rails_config
    valid_yaml = {
        "rails": [
            {"name": "rail_hard", "refusal_mode": "hard_block"},
            {"name": "rail_soft", "refusal_mode": "soft_steer"},
            {"name": "rail_info", "refusal_mode": "informative"},
        ]
    }
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".yaml", delete=False
    ) as f:
        yaml.dump(valid_yaml, f)
        temp_path = f.name
    try:
        rails = load_rails_config(temp_path)
        assert len(rails) == 3
        modes = {r.name: r.refusal_mode for r in rails}
        assert modes["rail_hard"] == "hard_block"
        assert modes["rail_soft"] == "soft_steer"
        assert modes["rail_info"] == "informative"
    finally:
        os.unlink(temp_path)


# --- critique_threshold tests (CSTL-04) ---

def test_critique_threshold_valid():
    """RailConfig with critique_threshold < threshold validates successfully."""
    from harness.config.rail_loader import RailConfig
    rc = RailConfig(name="x", threshold=0.7, critique_threshold=0.5)
    assert rc.critique_threshold == 0.5


def test_critique_threshold_none_valid():
    """RailConfig with critique_threshold=None validates successfully (no critique for this rail)."""
    from harness.config.rail_loader import RailConfig
    rc = RailConfig(name="x", threshold=0.7, critique_threshold=None)
    assert rc.critique_threshold is None


def test_critique_threshold_invalid():
    """RailConfig with critique_threshold >= threshold raises ValidationError."""
    from pydantic import ValidationError
    from harness.config.rail_loader import RailConfig
    with pytest.raises((ValidationError, ValueError)):
        RailConfig(name="x", threshold=0.7, critique_threshold=0.9)


def test_critique_threshold_equal_invalid():
    """RailConfig with critique_threshold == threshold raises ValidationError (must be strictly less)."""
    from pydantic import ValidationError
    from harness.config.rail_loader import RailConfig
    with pytest.raises((ValidationError, ValueError)):
        RailConfig(name="x", threshold=0.7, critique_threshold=0.7)


def test_rails_yaml_loads_with_critique_threshold():
    """load_rails_config on updated rails.yaml succeeds and output rails have critique_threshold set."""
    from harness.config.rail_loader import load_rails_config
    rails_path = os.path.join(
        os.path.dirname(__file__), "..", "config", "rails", "rails.yaml"
    )
    rails = load_rails_config(rails_path)
    rails_by_name = {r.name: r for r in rails}
    # Output rails have critique_threshold
    assert rails_by_name["self_check_output"].critique_threshold == 0.5
    assert rails_by_name["jailbreak_output"].critique_threshold == 0.5
    assert rails_by_name["sensitive_data_output"].critique_threshold == 0.15


def test_input_rails_no_critique_threshold():
    """Input rails in loaded config have critique_threshold=None."""
    from harness.config.rail_loader import load_rails_config
    rails_path = os.path.join(
        os.path.dirname(__file__), "..", "config", "rails", "rails.yaml"
    )
    rails = load_rails_config(rails_path)
    rails_by_name = {r.name: r for r in rails}
    # Input rails do NOT have critique_threshold
    assert rails_by_name["self_check_input"].critique_threshold is None
    assert rails_by_name["jailbreak_detection"].critique_threshold is None
    assert rails_by_name["sensitive_data_input"].critique_threshold is None
    assert rails_by_name["injection_heuristic"].critique_threshold is None
