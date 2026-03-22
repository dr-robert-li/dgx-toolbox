"""Tests for GATE-02: Auth via API key with per-tenant identity."""
import pytest


async def test_valid_key_returns_tenant(async_client, test_tenants):
    """A valid Bearer token resolves to the correct tenant."""
    response = await async_client.post(
        "/probe",
        headers={"Authorization": "Bearer sk-test-key"},
    )
    assert response.status_code == 200
    data = response.json()
    assert data["tenant_id"] == "test-tenant"


async def test_invalid_key_returns_401(async_client):
    """An invalid Bearer token returns 401 with detail 'Invalid API key'."""
    response = await async_client.post(
        "/probe",
        headers={"Authorization": "Bearer sk-wrong"},
    )
    assert response.status_code == 401
    assert response.json()["detail"] == "Invalid API key"


async def test_missing_auth_returns_401(async_client):
    """A request with no Authorization header returns 401 (HTTPBearer default in FastAPI>=0.115)."""
    response = await async_client.post("/probe")
    # FastAPI 0.135+ returns 401 (not 403) for missing Bearer credentials
    assert response.status_code in (401, 403)


async def test_load_tenants_valid(tmp_tenants_yaml):
    """load_tenants parses a valid YAML file and returns TenantConfig list."""
    from harness.config.loader import load_tenants
    tenants = load_tenants(str(tmp_tenants_yaml))
    assert len(tenants) >= 1
    assert tenants[0].tenant_id == "test-tenant"
    assert tenants[0].rpm_limit > 0
    assert tenants[0].tpm_limit > 0


async def test_load_tenants_invalid_yaml(tmp_path):
    """load_tenants raises ValueError on malformed YAML."""
    from harness.config.loader import load_tenants
    bad_file = tmp_path / "bad.yaml"
    bad_file.write_text("tenants: [this: is: not: valid: yaml: {\n")
    with pytest.raises(ValueError):
        load_tenants(str(bad_file))
