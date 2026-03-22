---
phase: 8
slug: eval-harness-and-ci-gate
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-23
---

# Phase 8 — Validation Strategy

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
| TBD | TBD | TBD | EVAL-01 | unit | `cd harness && python -m pytest tests/test_replay.py -v` | pending |
| TBD | TBD | TBD | EVAL-02 | unit | `cd harness && python -m pytest tests/test_lmeval.py -v` | pending |
| TBD | TBD | TBD | EVAL-03 | unit | `cd harness && python -m pytest tests/test_ci_gate.py -v` | pending |
| TBD | TBD | TBD | EVAL-04 | unit | `cd harness && python -m pytest tests/test_eval_store.py -v` | pending |

*Status: pending / green / red / flaky*

---

## Wave 0 Requirements

- [ ] Test fixtures for mock gateway responses
- [ ] Test JSONL dataset files
- [ ] Mock eval_runs data for trend tests

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| lm-eval benchmark scores plausible | EVAL-02 | Requires live model | Run `python -m harness.eval lm-eval` with real model, check scores are non-zero |
| Trend chart readability | EVAL-04 | Visual output | Run `python -m harness.eval trends --last 5`, verify ASCII chart renders correctly |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify commands
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all test files
- [ ] No watch-mode flags
- [ ] Feedback latency < 25s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
