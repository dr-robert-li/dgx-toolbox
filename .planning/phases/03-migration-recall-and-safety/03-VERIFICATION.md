---
phase: 03-migration-recall-and-safety
verified: 2026-03-21T14:00:00Z
status: passed
score: 11/11 must-haves verified
re_verification: false
---

# Phase 3: Migration, Recall, and Safety Verification Report

**Phase Goal:** Stale models are moved to cold storage automatically on a cron schedule and recalled transparently when needed, with atomic symlinks, concurrency guards, and disk warnings keeping the system safe
**Verified:** 2026-03-21
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| #  | Truth | Status | Evidence |
|----|-------|--------|----------|
| 1  | After a model exceeds retention, next cron run moves it to cold and replaces with symlink | VERIFIED | migrate.sh find_stale_hf_models() + hf_migrate_model dispatch; MIGR-02 test passes |
| 2  | Launcher detects cold symlink, recall moves it to hot and resets timer before consumer invoked | VERIFIED | watcher.sh readlink check + cmd/recall.sh --trigger=auto; RECL-01/02/03 tests pass |
| 3  | Two concurrent migration processes prevented — second exits with clear message | VERIFIED | migrate_cron.sh flock -n guard; MIGR-06 test confirms "already running" exit |
| 4  | `modelstore migrate --dry-run` shows what would move without moving any data | VERIFIED | migrate.sh DRY_RUN=true branch with two-section table; MIGR-07 test passes |
| 5  | If either drive exceeds 98%, desktop notification sent; falls back to alerts.log | VERIFIED | disk_check_cron.sh notify_user + alerts.log fallback; SAFE-03/04 tests pass |
| 6  | Running cmd/migrate.sh moves stale models to cold and creates symlinks | VERIFIED | 324-line orchestrator with full adapter dispatch; 12 migrate tests pass |
| 7  | Running cmd/migrate.sh --dry-run prints table without touching data | VERIFIED | DRY_RUN branch prints MODEL/SIZE/LAST USED/DAYS AGO/ACTION table; MIGR-07 test passes |
| 8  | Two concurrent migrate_cron.sh invocations do not overlap — second exits immediately | VERIFIED | flock -n 9 on LOCK_FILE in migrate_cron.sh (line 12); MIGR-06 confirmed |
| 9  | Ollama models with shared blobs only move blobs with hot ref count = 0 | VERIFIED | _ollama_blob_hot_refs() ref_count check; MIGR-05 test: shared blob stays regular file |
| 10 | Every migrate/recall/fail/disk_warning event writes JSON line to audit.log | VERIFIED | audit_log() with flock+jq; 9 audit tests pass including concurrent safety |
| 11 | Interrupted migration can resume from last completed phase via op_state.json | VERIFIED | _write_op_state/_clear_op_state; stale state (>4h) cleared at startup; SAFE-05 test passes |

**Score:** 11/11 truths verified

### Required Artifacts

| Artifact | Min Lines | Actual | Status | Details |
|----------|-----------|--------|--------|---------|
| `modelstore/lib/audit.sh` | — | 102 | VERIFIED | audit_log() + _audit_rotate_if_needed(); atomic flock append |
| `modelstore/lib/ollama_adapter.sh` | — | 242 | VERIFIED | _ollama_manifest_blobs, _ollama_blob_hot_refs, full migrate/recall bodies; no deferred stubs |
| `modelstore/cmd/migrate.sh` | 100 | 324 | VERIFIED | --dry-run, stale detection, op_state.json, adapter dispatch |
| `modelstore/cron/migrate_cron.sh` | 10 | 18 | VERIFIED | flock -n guard + TRIGGER_SOURCE=cron exec |
| `modelstore/test/test-migrate.sh` | 50 | 389 | VERIFIED | 12 tests, all pass; covers MIGR-01 through MIGR-07, SAFE-05 |
| `modelstore/test/test-audit.sh` | 30 | 165 | VERIFIED | 9 tests, all pass; covers MIGR-08 |
| `modelstore/lib/notify.sh` | — | 55 | VERIFIED | notify_user() with DBUS injection and alerts.log fallback |
| `modelstore/cmd/recall.sh` | 60 | 162 | VERIFIED | fuser guard, state file, usage.json reset, audit logging, adapter dispatch |
| `modelstore/cron/disk_check_cron.sh` | 30 | 88 | VERIFIED | check_disk_threshold x2, marker suppression, notify_user + audit_log |
| `modelstore/hooks/watcher.sh` | — | 209 | VERIFIED | auto-recall trigger added inside watch_inotify loop with readlink -f check |
| `modelstore/test/test-recall.sh` | 50 | 392 | VERIFIED | 12 tests, all pass; covers RECL-01, RECL-02, RECL-03 |
| `modelstore/test/test-disk-check.sh` | 40 | 325 | VERIFIED | 9 tests, all pass; covers SAFE-03, SAFE-04 |

All artifacts: exist, substantive (well above minimum lines), and wired.

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `cron/migrate_cron.sh` | `cmd/migrate.sh` | TRIGGER_SOURCE=cron exec | VERIFIED | Line 18: `TRIGGER_SOURCE=cron exec "${SCRIPT_DIR}/../cmd/migrate.sh" "$@"` |
| `cmd/migrate.sh` | `lib/hf_adapter.sh` | hf_migrate_model call | VERIFIED | Line 276: `if hf_migrate_model "$model_path" "$COLD_PATH"` |
| `cmd/migrate.sh` | `lib/ollama_adapter.sh` | ollama_migrate_model call | VERIFIED | Line 305: `if ollama_migrate_model "$model_name" "$COLD_PATH"` |
| `cmd/migrate.sh` | `lib/audit.sh` | audit_log after each operation | VERIFIED | 4 audit_log calls (migrate success, migrate fail, ollama success, ollama fail) |
| `cmd/migrate.sh` | `~/.modelstore/op_state.json` | _write_op_state/_clear_op_state | VERIFIED | 9 occurrences; write before each phase, clear after completion |
| `hooks/watcher.sh` | `cmd/recall.sh` | exec on cold symlink access | VERIFIED | Line 124: `"${SCRIPT_DIR}/../cmd/recall.sh" "$model_path" --trigger=auto` |
| `cmd/recall.sh` | `lib/hf_adapter.sh` | hf_recall_model call | VERIFIED | Line 114: `hf_recall_model "$MODEL_PATH" "$(dirname "$MODEL_PATH")"` |
| `cmd/recall.sh` | `~/.modelstore/usage.json` | timestamp reset after recall | VERIFIED | Lines 136-142: flock+jq atomic update with current timestamp |
| `cron/disk_check_cron.sh` | `lib/notify.sh` | notify_user call | VERIFIED | Line 64: `notify_user "modelstore: disk warning" ...` |
| `cron/disk_check_cron.sh` | `~/.modelstore/disk_alert_sent_*` | marker file for suppression | VERIFIED | Lines 42-43, 71: hash-based marker create/check/remove |

All 10 key links: WIRED.

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| MIGR-01 | 03-01 | Daily cron migrates stale models via rsync | SATISFIED | migrate_cron.sh + migrate.sh; test_cron_no_stale passes |
| MIGR-02 | 03-01 | Migrated models replaced with symlinks | SATISFIED | hf_migrate_model atomic symlink; test_symlink_created passes |
| MIGR-03 | 03-01 | Symlink replacement is atomic (ln + mv -T) | SATISFIED | hf_adapter.sh lines 102-103: `ln -s ... .new && mv -T`; test_atomic_swap passes |
| MIGR-04 | 03-01 | HF models migrated as whole models--*/ dirs | SATISFIED | hf_migrate_model rsync whole dir; test_hf_whole_dir passes |
| MIGR-05 | 03-01 | Ollama blob ref counting — shared blobs not moved if still referenced | SATISFIED | _ollama_blob_hot_refs() ref_count check; test_ollama_blob_refcount passes |
| MIGR-06 | 03-01 | Concurrent migrations prevented via flock | SATISFIED | migrate_cron.sh flock -n 9; test_flock_skip passes |
| MIGR-07 | 03-01 | dry-run shows what would migrate without moving data | SATISFIED | --dry-run table output; test_dry_run passes |
| MIGR-08 | 03-01 | All operations logged to audit file | SATISFIED | audit_log() JSON-line append; 9 audit tests pass |
| RECL-01 | 03-02 | Model moved back from cold to hot automatically when needed | SATISFIED | watcher.sh auto-recall on cold symlink access; test_auto_trigger passes |
| RECL-02 | 03-02 | Recall replaces symlink with real files and resets retention timer | SATISFIED | cmd/recall.sh symlink check + usage.json reset; test_symlink_replaced + test_timer_reset pass |
| RECL-03 | 03-02 | Launcher hooks trigger recall and update usage timestamps | SATISFIED | watcher.sh ms_track_usage + recall.sh --trigger=auto; test_launcher_hook passes |
| SAFE-03 | 03-02 | Cron sends desktop notification when drive exceeds 98% | SATISFIED | disk_check_cron.sh 98% threshold + notify_user; test_notify_threshold passes |
| SAFE-04 | 03-02 | Notifications fall back to log file without desktop session | SATISFIED | notify.sh alerts.log fallback; test_fallback_log passes |
| SAFE-05 | 03-01 | Multi-step operations use state file for interrupt-safe resumption | SATISFIED | op_state.json _write_op_state/_clear_op_state in migrate.sh and recall.sh; test_state_resume passes |

All 14 requirements: SATISFIED.

**Orphaned requirements check:** REQUIREMENTS.md maps exactly MIGR-01 through MIGR-08, RECL-01 through RECL-03, SAFE-03, SAFE-04, SAFE-05 to Phase 3. No orphaned requirements.

### Anti-Patterns Found

None. Scanned all 8 production files for: TODO/FIXME/XXX/HACK, placeholder text, "deferred to Phase 3" stubs, empty implementations (`return null/{}/<>`). All clean.

### Human Verification Required

#### 1. End-to-End Cron Migration on Real Hardware

**Test:** Install crontab entry, wait for next cron hour, verify a model past retention is on cold with symlink in hot.
**Expected:** Model directory becomes symlink; vLLM/transformers continue loading from same path.
**Why human:** Requires real mounted cold drive, real cron execution, real model directory.

#### 2. Desktop Notification on Disk Full

**Test:** Fill hot or cold drive to 98%+, run disk_check_cron.sh, verify desktop notification appears.
**Expected:** Notification popup with drive label, percentage, and "Run: modelstore migrate" guidance.
**Why human:** Requires GNOME desktop session; DBUS injection cannot be verified in test environment.

#### 3. Auto-Recall Latency Under vLLM Load

**Test:** Start vLLM with a model on cold storage, observe that recall completes before vLLM times out.
**Expected:** Transparent load — vLLM sees real files before attempting to read model weights.
**Why human:** Real inotify timing with actual model sizes (GB scale); cannot simulate with test fixtures.

### Gaps Summary

No gaps. All automated checks passed. 42 tests across 4 test files: 0 failures.

---

_Verified: 2026-03-21T14:00:00Z_
_Verifier: Claude (gsd-verifier)_
