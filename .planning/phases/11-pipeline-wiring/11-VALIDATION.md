---
phase: 11
slug: pipeline-wiring
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-24
---

# Phase 11 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash inline assertions (no bats — matches v1.0 pattern) |
| **Quick run command** | `bash scripts/test-pipeline.sh` |
| **Full suite command** | `bash scripts/test-pipeline.sh --full` |
| **Estimated runtime** | ~10 seconds (no model loading) |

---

## Sampling Rate

- **After every task commit:** Run quick test
- **After every plan wave:** Run full test
- **Max feedback latency:** 10 seconds

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Full pipeline with real model | All | Requires GPU + model download | Run demo script end-to-end with sample data |
| Data screening accuracy | DATA-03 | Requires harness running | Run screen-data.sh on test dataset, verify removals |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify commands
- [ ] Feedback latency < 10s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
