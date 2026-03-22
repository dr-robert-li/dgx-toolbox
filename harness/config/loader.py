"""Tenant configuration loader with Pydantic validation."""
from __future__ import annotations

from typing import Dict, List, Optional

import yaml
from pydantic import BaseModel, ValidationError


class TenantConfig(BaseModel):
    """Configuration for a single API tenant."""

    tenant_id: str
    api_key_hash: str
    rpm_limit: int = 60
    tpm_limit: int = 100_000
    allowed_models: List[str] = ["*"]
    bypass: bool = False
    pii_strictness: str = "balanced"
    rail_overrides: Dict[str, Dict[str, object]] = {}
    # Example: {"self_check_input": {"threshold": 0.9, "enabled": False}}


class TenantsFile(BaseModel):
    """Root schema for tenants.yaml."""

    tenants: List[TenantConfig]


def load_tenants(config_path: str) -> List[TenantConfig]:
    """Load and validate tenants from a YAML file.

    Args:
        config_path: Path to a tenants.yaml file.

    Returns:
        List of validated TenantConfig objects.

    Raises:
        ValueError: If the YAML is malformed or fails schema validation.
    """
    try:
        with open(config_path, "r") as f:
            raw = yaml.safe_load(f)
    except yaml.YAMLError as exc:
        raise ValueError(f"Failed to parse tenants YAML: {exc}") from exc

    if raw is None:
        raise ValueError("Tenants file is empty")

    try:
        parsed = TenantsFile.model_validate(raw)
    except ValidationError as exc:
        raise ValueError(f"Tenants schema validation failed: {exc}") from exc

    return parsed.tenants
