---
phase: 10
slug: hitl-dashboard
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-23
---

# Phase 10 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | pytest 8.x with pytest-asyncio |
| **Config file** | harness/pyproject.toml `[tool.pytest.ini_options]` |
| **Quick run command** | `cd harness && python -m pytest tests/ -x -q` |
| **Full suite command** | `cd harness && python -m pytest tests/ -v` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `cd harness && python -m pytest tests/ -x -q`
- **After every plan wave:** Run `cd harness && python -m pytest tests/ -v`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

*To be updated by planner with actual task IDs and test files.*

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | Status |
|---------|------|------|-------------|-----------|-------------------|--------|
| TBD | TBD | TBD | HITL-01 | unit | `cd harness && python -m pytest tests/test_hitl.py -v` | pending |
| TBD | TBD | TBD | HITL-02 | unit | `cd harness && python -m pytest tests/test_hitl.py -v` | pending |
| TBD | TBD | TBD | HITL-03 | unit | `cd harness && python -m pytest tests/test_hitl.py -v` | pending |
| TBD | TBD | TBD | HITL-04 | unit | `cd harness && python -m pytest tests/test_hitl.py -v` | pending |

---

## Wave 0 Requirements

- [ ] Mock trace data with guardrail_decisions and cai_critique for queue tests
- [ ] Mock correction data for calibration and export tests

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Gradio UI renders correctly | HITL-01 | Visual layout | Start `python -m harness.hitl ui`, verify two-panel layout |
| Side-by-side diff readability | HITL-02 | Visual output | Click a queue item, verify diff highlights are readable |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify commands
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all test files
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
