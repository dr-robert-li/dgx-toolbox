---
phase: 6
slug: input-output-guardrails-and-refusal
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-22
---

# Phase 6 — Validation Strategy

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
| TBD | TBD | TBD | INRL-01 | unit | `cd harness && python -m pytest tests/test_normalize.py -v` | pending |
| TBD | TBD | TBD | INRL-02 | unit | `cd harness && python -m pytest tests/test_input_rails.py -v` | pending |
| TBD | TBD | TBD | INRL-03 | unit | `cd harness && python -m pytest tests/test_input_rails.py -v` | pending |
| TBD | TBD | TBD | INRL-04 | unit | `cd harness && python -m pytest tests/test_input_rails.py -v` | pending |
| TBD | TBD | TBD | INRL-05 | unit | `cd harness && python -m pytest tests/test_rail_config.py -v` | pending |
| TBD | TBD | TBD | OURL-01 | unit | `cd harness && python -m pytest tests/test_output_rails.py -v` | pending |
| TBD | TBD | TBD | OURL-02 | unit | `cd harness && python -m pytest tests/test_output_rails.py -v` | pending |
| TBD | TBD | TBD | OURL-03 | unit | `cd harness && python -m pytest tests/test_output_rails.py -v` | pending |
| TBD | TBD | TBD | OURL-04 | unit | `cd harness && python -m pytest tests/test_rail_config.py -v` | pending |
| TBD | TBD | TBD | REFU-01 | unit | `cd harness && python -m pytest tests/test_refusal.py -v` | pending |
| TBD | TBD | TBD | REFU-02 | integration | `cd harness && python -m pytest tests/test_refusal.py -v` | pending |
| TBD | TBD | TBD | REFU-03 | unit | `cd harness && python -m pytest tests/test_refusal.py -v` | pending |
| TBD | TBD | TBD | REFU-04 | unit | `cd harness && python -m pytest tests/test_rail_config.py -v` | pending |

*Status: pending / green / red / flaky*

---

## Wave 0 Requirements

- [ ] Test infrastructure extended with guardrail test fixtures
- [ ] Mock NeMo rails for unit testing (no real LLM calls)
- [ ] pytest-asyncio for async rail execution tests

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| NeMo LLM-as-judge quality | INRL-04 | Requires actual model inference | Send known jailbreak prompts, verify detection rate |
| Soft-steer rewrite quality | REFU-02 | Requires actual model inference | Verify rewritten prompts are semantically appropriate |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify commands
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all test files
- [ ] No watch-mode flags
- [ ] Feedback latency < 20s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
