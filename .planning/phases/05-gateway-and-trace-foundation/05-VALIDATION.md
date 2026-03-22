---
phase: 5
slug: gateway-and-trace-foundation
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-22
---

# Phase 5 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | pytest 7.x |
| **Config file** | pyproject.toml or "none — Wave 0 installs" |
| **Quick run command** | `pytest tests/gateway/ -x -q` |
| **Full suite command** | `pytest tests/gateway/ -v` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `pytest tests/gateway/ -x -q`
- **After every plan wave:** Run `pytest tests/gateway/ -v`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 05-01-01 | 01 | 0 | GATE-01 | integration | `pip install nemoguardrails && python -c "from nemoguardrails import LLMRails"` | ❌ W0 | ⬜ pending |
| 05-02-01 | 02 | 1 | GATE-02 | unit | `pytest tests/gateway/test_auth.py -v` | ❌ W0 | ⬜ pending |
| 05-02-02 | 02 | 1 | GATE-03 | unit | `pytest tests/gateway/test_rate_limit.py -v` | ❌ W0 | ⬜ pending |
| 05-03-01 | 03 | 1 | GATE-04 | integration | `pytest tests/gateway/test_proxy.py -v` | ❌ W0 | ⬜ pending |
| 05-03-02 | 03 | 1 | GATE-05 | integration | `pytest tests/gateway/test_bypass.py -v` | ❌ W0 | ⬜ pending |
| 05-04-01 | 04 | 2 | TRAC-01 | unit | `pytest tests/gateway/test_trace.py -v` | ❌ W0 | ⬜ pending |
| 05-04-02 | 04 | 2 | TRAC-02 | unit | `pytest tests/gateway/test_pii.py -v` | ❌ W0 | ⬜ pending |
| 05-04-03 | 04 | 2 | TRAC-03 | unit | `pytest tests/gateway/test_trace_query.py -v` | ❌ W0 | ⬜ pending |
| 05-04-04 | 04 | 2 | TRAC-04 | unit | `pytest tests/gateway/test_trace_query.py -v` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/gateway/conftest.py` — shared fixtures (mock LiteLLM, test SQLite DB)
- [ ] `tests/gateway/test_auth.py` — stubs for GATE-02
- [ ] `tests/gateway/test_rate_limit.py` — stubs for GATE-03
- [ ] `tests/gateway/test_proxy.py` — stubs for GATE-04, GATE-05
- [ ] `tests/gateway/test_trace.py` — stubs for TRAC-01, TRAC-02
- [ ] `tests/gateway/test_trace_query.py` — stubs for TRAC-03, TRAC-04
- [ ] `tests/gateway/test_pii.py` — stubs for TRAC-02
- [ ] pytest + httpx + aiosqlite installed as test dependencies

*If none: "Existing infrastructure covers all phase requirements."*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| NeMo Guardrails aarch64 install | GATE-01 | Requires actual DGX Spark hardware | SSH to DGX Spark, create fresh venv, `pip install nemoguardrails`, verify `LLMRails()` instantiates |
| Latency < 50ms overhead | GATE-04 | Requires live LiteLLM backend | Compare response times with/without gateway proxy |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
