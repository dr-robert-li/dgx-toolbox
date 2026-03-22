---
phase: 7
slug: constitutional-ai-critique
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-22
---

# Phase 7 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | pytest 8.x with pytest-asyncio |
| **Config file** | harness/pyproject.toml `[tool.pytest.ini_options]` |
| **Quick run command** | `cd harness && python -m pytest tests/ -x -q` |
| **Full suite command** | `cd harness && python -m pytest tests/ -v` |
| **Estimated runtime** | ~20 seconds |

---

## Sampling Rate

- **After every task commit:** Run `cd harness && python -m pytest tests/ -x -q`
- **After every plan wave:** Run `cd harness && python -m pytest tests/ -v`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 20 seconds

---

## Per-Task Verification Map

*To be updated by planner with actual task IDs and test files.*

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | Status |
|---------|------|------|-------------|-----------|-------------------|--------|
| TBD | TBD | TBD | CSTL-01 | unit | `cd harness && python -m pytest tests/test_critique.py -v` | pending |
| TBD | TBD | TBD | CSTL-02 | unit | `cd harness && python -m pytest tests/test_constitution.py -v` | pending |
| TBD | TBD | TBD | CSTL-03 | unit | `cd harness && python -m pytest tests/test_critique.py -v` | pending |
| TBD | TBD | TBD | CSTL-04 | unit | `cd harness && python -m pytest tests/test_critique.py -v` | pending |
| TBD | TBD | TBD | CSTL-05 | integration | `cd harness && python -m pytest tests/test_tuning.py -v` | pending |

*Status: pending / green / red / flaky*

---

## Wave 0 Requirements

- [ ] Test fixtures for mock judge model responses
- [ ] Test constitution.yaml fixtures
- [ ] pytest-asyncio for async critique tests

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Judge model latency on aarch64 | CSTL-01 | Requires live model inference | Time critique cycle with real model, verify < 60s |
| Tuning suggestion quality | CSTL-05 | Requires real trace history and model judgment | Run analyze on real traces, review suggestion relevance |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify commands
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all test files
- [ ] No watch-mode flags
- [ ] Feedback latency < 20s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
