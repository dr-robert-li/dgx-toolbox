"""In-memory per-tenant sliding window rate limiter for RPM and TPM."""
from __future__ import annotations

import asyncio
import time
from collections import defaultdict, deque


class RateLimitExceeded(Exception):
    """Raised when a tenant has exceeded a rate limit."""

    def __init__(self, detail: str) -> None:
        super().__init__(detail)
        self.detail = detail


class SlidingWindowLimiter:
    """Thread-safe (asyncio) per-tenant sliding window limiter.

    RPM gate: checked and recorded PRE-request.
    TPM gate: recorded POST-response; checked PRE-next-request (one-request lag by design).
    """

    WINDOW = 60.0  # seconds

    def __init__(self) -> None:
        self._rpm_log: dict[str, deque] = defaultdict(deque)
        self._tpm_log: dict[str, deque[tuple[float, int]]] = defaultdict(deque)
        self._lock = asyncio.Lock()

    async def check_rpm(self, tenant_id: str, rpm_limit: int) -> None:
        """Check and record a request against the RPM limit.

        Raises:
            RateLimitExceeded: If the tenant has exceeded rpm_limit requests/minute.
        """
        async with self._lock:
            now = time.monotonic()
            q = self._rpm_log[tenant_id]
            # Expire entries outside the window
            while q and q[0] < now - self.WINDOW:
                q.popleft()
            if len(q) >= rpm_limit:
                raise RateLimitExceeded("RPM limit exceeded")
            q.append(now)

    async def check_tpm(self, tenant_id: str, tpm_limit: int) -> None:
        """Check accumulated tokens against the TPM limit (pre-next-request gate).

        Raises:
            RateLimitExceeded: If total tokens in the current window exceed tpm_limit.
        """
        async with self._lock:
            now = time.monotonic()
            q = self._tpm_log[tenant_id]
            # Expire entries outside the window
            while q and q[0][0] < now - self.WINDOW:
                q.popleft()
            total = sum(tokens for _, tokens in q)
            if total > tpm_limit:
                raise RateLimitExceeded("TPM limit exceeded")

    async def record_tpm(self, tenant_id: str, tokens: int) -> None:
        """Record token usage after a response is received.

        Args:
            tenant_id: The tenant to charge.
            tokens: Number of tokens used in this request/response.
        """
        async with self._lock:
            self._tpm_log[tenant_id].append((time.monotonic(), tokens))
