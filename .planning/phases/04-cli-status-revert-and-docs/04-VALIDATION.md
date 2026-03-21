---
phase: 4
slug: cli-status-revert-and-docs
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-22
---

# Phase 4 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Inline bash assertions (matching Phase 1-3 pattern) |
| **Config file** | none — test files are self-contained |
| **Quick run command** | `bash modelstore/test/run-all.sh` |
| **Full suite command** | `bash modelstore/test/run-all.sh` |
| **Estimated runtime** | ~25 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash modelstore/test/run-all.sh`
- **After every plan wave:** Run `bash modelstore/test/run-all.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 25 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 04-01-01 | 01 | 1 | CLI-01,03 | unit | `bash modelstore/test/test-status.sh` | ❌ W0 | ⬜ pending |
| 04-01-02 | 01 | 1 | CLI-04,05 | unit | `bash modelstore/test/test-revert.sh` | ❌ W0 | ⬜ pending |
| 04-02-01 | 02 | 2 | CLI-02,06,07 | unit | `bash modelstore/test/test-cli.sh` | ❌ W0 | ⬜ pending |
| 04-02-02 | 02 | 2 | DOCS-01,02,03,04 | grep | `grep -q "Model Store" README.md && grep -q "modelstore" CHANGELOG.md` | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `modelstore/test/test-status.sh` — status table output, dashboard sections, broken symlink detection
- [ ] `modelstore/test/test-revert.sh` — preview output, --force bypass, interrupt resume, cleanup scope
- [ ] `modelstore/test/test-cli.sh` — dispatcher routing, headless output, progress bar detection

*Wave 0 creates test infrastructure alongside implementation.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Status dashboard with real models | CLI-03 | Requires real HF/Ollama models | Run `modelstore status` on DGX |
| Revert moves real cold models back | CLI-04 | Requires migrated models | Migrate a model, then run `modelstore revert` |
| Progress bars visible in terminal | CLI-06 | Requires TTY + large transfer | Run migrate/revert on real model |
| README paths correct after reorg | DOCS-01 | Visual inspection | Read README, verify all script paths exist |
| NVIDIA Sync custom app commands work | DOCS-01 | Requires Sync setup | Test `sg docker -c` commands from README |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 25s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
