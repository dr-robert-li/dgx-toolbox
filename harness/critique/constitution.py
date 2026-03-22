"""Constitution configuration loader with Pydantic validation.

Follows the same pattern as harness/config/rail_loader.py.
Invalid constitution.yaml causes a ValueError at load time, never a silent fallback.
"""
from __future__ import annotations

from typing import List

import yaml
from pydantic import BaseModel, ValidationError


class Principle(BaseModel):
    """A single constitutional principle."""

    id: str
    text: str
    category: str
    priority: float
    enabled: bool = True


class ConstitutionConfig(BaseModel):
    """Validated constitution configuration (inner object)."""

    judge_model: str = "default"
    principles: List[Principle]


class ConstitutionFile(BaseModel):
    """Root schema for constitution.yaml."""

    constitution: ConstitutionConfig


def load_constitution(config_path: str) -> ConstitutionConfig:
    """Load and validate a constitution from a YAML file.

    Args:
        config_path: Path to a constitution.yaml file.

    Returns:
        Validated ConstitutionConfig object.

    Raises:
        ValueError: If the YAML is malformed, empty, or fails schema validation.
    """
    try:
        with open(config_path, "r") as f:
            raw = yaml.safe_load(f)
    except yaml.YAMLError as exc:
        raise ValueError(f"Failed to parse constitution YAML: {exc}") from exc

    if raw is None:
        raise ValueError("Constitution config file is empty")

    try:
        parsed = ConstitutionFile.model_validate(raw)
    except ValidationError as exc:
        raise ValueError(f"Constitution schema validation failed: {exc}") from exc

    return parsed.constitution
