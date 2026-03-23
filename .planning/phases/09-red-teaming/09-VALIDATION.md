---
phase: 9
slug: red-teaming
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-23
---

# Phase 9 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | pytest 8.x with pytest-asyncio |
| **Config file** | harness/pyproject.toml `[tool.pytest.ini_options]` |
| **Quick run command** | `cd harness && python -m pytest tests/ -x -q` |
| **Full suite command** | `cd harness && python -m pytest tests/ -v` |
| **Estimated runtime** | ~25 seconds |

---

## Sampling Rate

- **After every task commit:** Run `cd harness && python -m pytest tests/ -x -q`
- **After every plan wave:** Run `cd harness && python -m pytest tests/ -v`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 25 seconds

---

## Per-Task Verification Map

*To be updated by planner with actual task IDs and test files.*

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | Status |
|---------|------|------|-------------|-----------|-------------------|--------|
| TBD | TBD | TBD | RDTM-01 | unit | `cd harness && python -m pytest tests/test_garak.py -v` | pending |
| TBD | TBD | TBD | RDTM-02 | unit | `cd harness && python -m pytest tests/test_deepteam.py -v` | pending |
| TBD | TBD | TBD | RDTM-03 | unit | `cd harness && python -m pytest tests/test_redteam_jobs.py -v` | pending |
| TBD | TBD | TBD | RDTM-04 | unit | `cd harness && python -m pytest tests/test_balance.py -v` | pending |

---

## Wave 0 Requirements

- [ ] Mock garak subprocess output fixtures
- [ ] Mock judge model response fixtures for adversarial generation
- [ ] Test near-miss trace data fixtures

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| garak scan against live gateway | RDTM-01 | Requires running harness + model | Start harness, run `python -m harness.redteam garak --profile quick` |
| deepteam generation quality | RDTM-02 | Requires live judge model | Run deepteam job, review pending JSONL for adversarial quality |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify commands
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all test files
- [ ] No watch-mode flags
- [ ] Feedback latency < 25s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
