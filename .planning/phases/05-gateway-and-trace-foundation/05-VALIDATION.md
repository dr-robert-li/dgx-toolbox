---
phase: 5
slug: gateway-and-trace-foundation
status: draft
nyquist_compliant: true
wave_0_complete: true
created: 2026-03-22
---

# Phase 5 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | pytest 8.x with pytest-asyncio |
| **Config file** | harness/pyproject.toml `[tool.pytest.ini_options]` |
| **Quick run command** | `cd harness && python -m pytest tests/ -x -q` |
| **Full suite command** | `cd harness && python -m pytest tests/ -v` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `cd harness && python -m pytest tests/ -x -q`
- **After every plan wave:** Run `cd harness && python -m pytest tests/ -v`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | Status |
|---------|------|------|-------------|-----------|-------------------|--------|
| 05-01-T1 | 01 | 1 | GATE-02 | unit | `cd harness && python -m pytest tests/test_auth.py -v` | pending |
| 05-01-T2 | 01 | 1 | GATE-03 | unit | `cd harness && python -m pytest tests/test_ratelimit.py -v` | pending |
| 05-02-T1 | 02 | 2 | TRAC-01, TRAC-02, TRAC-03, TRAC-04 | unit | `cd harness && python -m pytest tests/test_pii.py tests/test_traces.py -v` | pending |
| 05-02-T2 | 02 | 2 | GATE-01, GATE-04, GATE-05 | integration | `cd harness && python -m pytest tests/test_proxy.py -v` | pending |
| 05-03-T1 | 03 | 1 | (Phase 6 enabler) | unit | `cd harness && python -m pytest tests/test_nemo_compat.py -v` | pending |
| 05-03-T2 | 03 | 1 | (Phase 6 enabler) | manual | `bash harness/scripts/validate_aarch64.sh` on DGX Spark | pending |

*Status: pending / green / red / flaky*

---

## Wave 0 Requirements

All test infrastructure is created inline by each plan's tasks:

- [x] `harness/pyproject.toml` — pytest config and test dependencies (Plan 01, Task 1)
- [x] `harness/tests/__init__.py` — test package init (Plan 01, Task 1)
- [x] `harness/tests/conftest.py` — shared fixtures: async_client, test tenants, mock LiteLLM (Plan 01, Task 1)
- [x] `harness/tests/test_auth.py` — auth tests (Plan 01, Task 1)
- [x] `harness/tests/test_ratelimit.py` — rate limiter tests (Plan 01, Task 2)
- [x] `harness/tests/test_pii.py` — PII redaction tests (Plan 02, Task 1)
- [x] `harness/tests/test_traces.py` — trace store tests (Plan 02, Task 1)
- [x] `harness/tests/test_proxy.py` — proxy route integration tests (Plan 02, Task 2)
- [x] `harness/tests/test_nemo_compat.py` — NeMo compat smoke tests (Plan 03, Task 1)

Each plan uses TDD (`tdd="true"` on tasks) — tests are written before implementation within each task. No separate Wave 0 plan needed.

*Existing infrastructure covers all phase requirements.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| NeMo Guardrails aarch64 install | Phase 6 enabler | Requires actual DGX Spark hardware | SSH to DGX Spark, run `bash harness/scripts/validate_aarch64.sh /tmp/harness-compat-test` |
| Latency < 50ms overhead | GATE-04 | Requires live LiteLLM backend | Compare response times with/without gateway proxy |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify commands
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all test files (inline with TDD tasks)
- [x] No watch-mode flags
- [x] Feedback latency < 15s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
