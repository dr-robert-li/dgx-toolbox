---
phase: 3
slug: migration-recall-and-safety
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-21
---

# Phase 3 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Inline bash assertions (matching Phase 1/2 pattern) |
| **Config file** | none — test files are self-contained |
| **Quick run command** | `bash modelstore/test/run-all.sh` |
| **Full suite command** | `bash modelstore/test/run-all.sh` |
| **Estimated runtime** | ~20 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash modelstore/test/run-all.sh`
- **After every plan wave:** Run `bash modelstore/test/run-all.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 20 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 03-01-01 | 01 | 1 | MIGR-01,02,03,04,05,06,07 | unit | `bash modelstore/test/test-migrate.sh` | ❌ W0 | ⬜ pending |
| 03-01-02 | 01 | 1 | MIGR-08, SAFE-05 | unit | `bash modelstore/test/test-audit.sh` | ❌ W0 | ⬜ pending |
| 03-02-01 | 02 | 2 | RECL-01,02,03 | unit | `bash modelstore/test/test-recall.sh` | ❌ W0 | ⬜ pending |
| 03-02-02 | 02 | 2 | SAFE-03,04 | unit | `bash modelstore/test/test-disk-check.sh` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `modelstore/test/test-migrate.sh` — cron no-stale, symlink created, atomic swap, HF whole dir, Ollama blob refcount, flock skip, dry-run, state resume
- [ ] `modelstore/test/test-audit.sh` — migrate logged, recall logged, failure logged, disk warning logged
- [ ] `modelstore/test/test-recall.sh` — auto trigger, symlink replaced, launcher hook, timer reset
- [ ] `modelstore/test/test-disk-check.sh` — notify threshold, fallback log, suppression marker

*Wave 0 creates test infrastructure alongside implementation.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Cron fires at configured hour | MIGR-01 | Requires waiting for cron schedule | Check `crontab -l`, verify entry, wait for execution |
| notify-send shows desktop notification | SAFE-03 | Requires active GNOME session | Manually trigger disk_check_cron while logged in |
| Watcher auto-recalls on cold access | RECL-01 | Requires migrated model + live watcher | Migrate a model, access its symlink, verify recall starts |
| Large model recall blocks consumer | RECL-01 | Requires real model (24GB+) | Trigger recall of nemotron-cascade-2, observe wait time |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 20s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
