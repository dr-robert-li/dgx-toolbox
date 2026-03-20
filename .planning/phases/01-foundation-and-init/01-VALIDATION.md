---
phase: 1
slug: foundation-and-init
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-21
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash + bats-core (if available) or inline bash assertions |
| **Config file** | none — Phase 1 creates the infrastructure |
| **Quick run command** | `bash ~/dgx-toolbox/modelstore/test/smoke.sh` |
| **Full suite command** | `bash ~/dgx-toolbox/modelstore/test/run-all.sh` |
| **Estimated runtime** | ~10 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash ~/dgx-toolbox/modelstore/test/smoke.sh`
- **After every plan wave:** Run `bash ~/dgx-toolbox/modelstore/test/run-all.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 10 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 01-01-01 | 01 | 1 | INIT-05 | unit | `bash -c 'source modelstore/lib/config.sh && test -n "$(type -t config_load)"'` | ❌ W0 | ⬜ pending |
| 01-01-02 | 01 | 1 | SAFE-01 | unit | `bash -c 'source modelstore/lib/common.sh && type -t check_mount'` | ❌ W0 | ⬜ pending |
| 01-02-01 | 02 | 1 | INIT-01 | integration | `echo "" \| bash modelstore/cmd/init.sh --test` | ❌ W0 | ⬜ pending |
| 01-02-02 | 02 | 1 | INIT-06 | integration | `bash modelstore/test/test-fs-validation.sh` | ❌ W0 | ⬜ pending |
| 01-02-03 | 02 | 1 | INIT-07 | integration | `bash modelstore/test/test-init.sh` | ❌ W0 | ⬜ pending |
| 01-02-04 | 02 | 1 | INIT-08 | integration | `bash modelstore/test/test-init.sh` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `modelstore/test/smoke.sh` — basic function existence and config read/write
- [ ] `modelstore/test/run-all.sh` — runs all test scripts
- [ ] `modelstore/test/test-fs-validation.sh` — filesystem rejection tests
- [ ] `modelstore/test/test-init.sh` — init function integration tests (model scan, config round-trip, dir creation)
*Wave 0 creates test infrastructure alongside implementation.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| gum interactive UI renders correctly | INIT-01 | Requires TTY + visual inspection | Run `modelstore init` in terminal, verify gum prompts display |
| Filesystem tree preview shows correct drives | INIT-01 | Requires mounted drives | Run init, verify lsblk output matches `lsblk` directly |
| Config backup retention cleanup | INIT-08 | Requires 30-day-old backups | Create old backup files, run reinit, verify cleanup |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 10s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
