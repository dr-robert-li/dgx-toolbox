"""Shared fixtures for all harness tests."""
import pytest
import pytest_asyncio
from pathlib import Path
from argon2 import PasswordHasher
from httpx import AsyncClient, ASGITransport

from harness.config.loader import TenantConfig
from harness.main import app


_ph = PasswordHasher()


@pytest.fixture
def test_tenants():
    """Return a list of TenantConfig with known test values."""
    return [
        TenantConfig(
            tenant_id="test-tenant",
            api_key_hash=_ph.hash("sk-test-key"),
            rpm_limit=60,
            tpm_limit=100000,
            allowed_models=["*"],
            bypass=False,
            pii_strictness="balanced",
        ),
        TenantConfig(
            tenant_id="bypass-tenant",
            api_key_hash=_ph.hash("sk-bypass-key"),
            rpm_limit=120,
            tpm_limit=500000,
            allowed_models=["*"],
            bypass=True,
            pii_strictness="minimal",
        ),
    ]


@pytest.fixture
def tmp_tenants_yaml(tmp_path, test_tenants):
    """Write a temporary tenants.yaml with known hashes."""
    import yaml
    tenants_data = {
        "tenants": [
            {
                "tenant_id": t.tenant_id,
                "api_key_hash": t.api_key_hash,
                "rpm_limit": t.rpm_limit,
                "tpm_limit": t.tpm_limit,
                "allowed_models": t.allowed_models,
                "bypass": t.bypass,
                "pii_strictness": t.pii_strictness,
            }
            for t in test_tenants
        ]
    }
    yaml_file = tmp_path / "tenants.yaml"
    yaml_file.write_text(yaml.dump(tenants_data))
    return yaml_file


@pytest_asyncio.fixture
async def async_client(test_tenants):
    """AsyncClient with ASGITransport for testing FastAPI without a live server."""
    from harness.ratelimit.sliding_window import SlidingWindowLimiter

    # Override app state with test fixtures
    app.state.tenants = test_tenants
    app.state.rate_limiter = SlidingWindowLimiter()

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as ac:
        yield ac
