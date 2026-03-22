"""Rail configuration loader with Pydantic validation.

Follows the same pattern as harness/config/loader.py (TenantConfig).
Invalid rails.yaml causes a ValueError at load time, never a silent fallback.
"""
from __future__ import annotations

from typing import List, Literal, Optional

import yaml
from pydantic import BaseModel, ValidationError, model_validator


class RailConfig(BaseModel):
    """Configuration for a single guardrail."""

    name: str
    enabled: bool = True
    threshold: float = 0.7
    refusal_mode: Literal["hard_block", "soft_steer", "informative"] = "hard_block"
    critique_threshold: Optional[float] = None

    @model_validator(mode='after')
    def validate_critique_threshold(self) -> 'RailConfig':
        """Ensure critique_threshold is strictly less than threshold when set."""
        if self.critique_threshold is not None:
            if self.critique_threshold >= self.threshold:
                raise ValueError(
                    f"Rail '{self.name}': critique_threshold ({self.critique_threshold}) "
                    f"must be less than threshold ({self.threshold})"
                )
        return self


class RailsFile(BaseModel):
    """Root schema for rails.yaml."""

    rails: List[RailConfig]


def load_rails_config(config_path: str) -> List[RailConfig]:
    """Load and validate rails from a YAML file.

    Args:
        config_path: Path to a rails.yaml file.

    Returns:
        List of validated RailConfig objects.

    Raises:
        ValueError: If the YAML is malformed, empty, or fails schema validation.
    """
    try:
        with open(config_path, "r") as f:
            raw = yaml.safe_load(f)
    except yaml.YAMLError as exc:
        raise ValueError(f"Failed to parse rails YAML: {exc}") from exc

    if raw is None:
        raise ValueError("Rails config file is empty")

    try:
        parsed = RailsFile.model_validate(raw)
    except ValidationError as exc:
        raise ValueError(f"Rails schema validation failed: {exc}") from exc

    return parsed.rails
