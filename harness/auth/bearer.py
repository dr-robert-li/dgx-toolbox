"""HTTPBearer auth dependency — verifies API keys against tenant hashes."""
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError, VerificationError, InvalidHashError
from fastapi import Depends, HTTPException, Request
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials

from harness.config.loader import TenantConfig

_ph = PasswordHasher()
_bearer = HTTPBearer()


async def verify_api_key(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer),
    request: Request = None,
) -> TenantConfig:
    """FastAPI dependency that verifies a Bearer token against tenant hashes.

    Returns the matching TenantConfig on success.
    Raises HTTP 401 if the key does not match any tenant.
    """
    token = credentials.credentials
    for tenant in request.app.state.tenants:
        try:
            _ph.verify(tenant.api_key_hash, token)
            return tenant
        except (VerifyMismatchError, VerificationError, InvalidHashError):
            continue
    raise HTTPException(status_code=401, detail="Invalid API key")
