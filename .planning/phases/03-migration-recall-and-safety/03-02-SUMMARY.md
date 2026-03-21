---
phase: 03-migration-recall-and-safety
plan: 02
subsystem: storage
tags: [bash, recall, notify-send, dbus, inotify, flock, cron, audit-log]

# Dependency graph
requires:
  - phase: 03-01
    provides: audit.sh, migrate.sh, migrate_cron.sh with op_state.json pattern
  - phase: 02-01
    provides: hf_adapter.sh (hf_recall_model), ollama_adapter.sh (ollama_recall_model), watcher.sh (watch_inotify, ms_track_usage)

provides:
  - lib/notify.sh with notify_user() — DBUS injection from /proc/<gnome-session>/environ with systemd fallback, alerts.log fallback
  - cmd/recall.sh — synchronous recall with fuser guard, op_state.json SAFE-05 interrupt safety, usage timestamp reset, adapter dispatch, audit logging
  - cron/disk_check_cron.sh — 98% threshold check, marker file suppression, notify_user + audit_log
  - hooks/watcher.sh extended — cold symlink detection via readlink in watch_inotify() loop, auto-recall via recall.sh --trigger=auto
  - test/test-recall.sh — 12 tests covering RECL-01, RECL-02, RECL-03
  - test/test-disk-check.sh — 9 tests covering SAFE-03, SAFE-04

affects:
  - 04-cli-and-status (recall cmd dispatch, disk status display)
  - 03-03 (if any final phase plan)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - fuser -s guard before auto-recall prevents disrupting active inference
    - md5sum path hash for drive-specific marker files (disk_alert_sent_<hash>)
    - DBUS injection from /proc/<gnome-session-pid>/environ with unix:path=/run/user/$uid/bus fallback
    - Watcher extend-not-rewrite: auto-recall trigger added inline after ms_track_usage call

key-files:
  created:
    - modelstore/lib/notify.sh
    - modelstore/cmd/recall.sh
    - modelstore/cron/disk_check_cron.sh
    - modelstore/test/test-recall.sh
    - modelstore/test/test-disk-check.sh
  modified:
    - modelstore/hooks/watcher.sh

key-decisions:
  - "Test RECL-03 launcher_hook sets COLD_PATH directly ($TMP/cold) instead of calling load_config to avoid reading real system config"
  - "check_disk_threshold inlined in test-disk-check.sh (same pattern as watcher tests) to allow df/notify_user mocking without subprocess complexity"

patterns-established:
  - "Pattern: fuser -s <path> as pre-recall guard for auto-trigger — fast check, exits immediately if files open"
  - "Pattern: marker file name = disk_alert_sent_$(echo path | md5sum | cut -d' ' -f1) — stable hash per drive"
  - "Pattern: DBUS injection: grep -z DBUS_SESSION_BUS_ADDRESS /proc/<pid>/environ then fallback to unix:path=/run/user/$uid/bus"
  - "Pattern: tests that need COLD_PATH/HOT_HF_PATH avoid load_config and set env vars directly to prevent reading real system config"

requirements-completed: [RECL-01, RECL-02, RECL-03, SAFE-03, SAFE-04]

# Metrics
duration: 6min
completed: 2026-03-21
---

# Phase 3 Plan 2: Recall Pipeline and Disk Safety Summary

**Synchronous recall via cmd/recall.sh with fuser guard, watcher auto-recall on cold symlink access, and disk_check_cron.sh with 98% threshold/marker suppression/DBUS notifications**

## Performance

- **Duration:** 6 min
- **Started:** 2026-03-21T13:07:37Z
- **Completed:** 2026-03-21T13:13:37Z
- **Tasks:** 3
- **Files modified:** 6 (5 created, 1 extended)

## Accomplishments

- cmd/recall.sh: synchronous recall with fuser guard (RECL-01), adapter dispatch for HF and Ollama paths, usage.json timestamp reset (RECL-02), audit logging with trigger field (RECL-03), op_state.json interrupt safety (SAFE-05)
- lib/notify.sh: DBUS session address injection from /proc/<gnome-session>/environ, systemd user bus socket fallback, alerts.log fallback (SAFE-04)
- cron/disk_check_cron.sh: 98% threshold check for both hot and cold drives, md5sum-hashed marker files for per-drive suppression, notify_user + audit_log on first crossing (SAFE-03)
- watcher.sh extended: cold symlink detection with readlink -f, auto-recall trigger calls recall.sh --trigger=auto (RECL-01)
- 21 tests pass: 12 in test-recall.sh, 9 in test-disk-check.sh

## Task Commits

Each task was committed atomically:

1. **Task 1: Create lib/notify.sh and cmd/recall.sh** - `d0983b0` (feat)
2. **Task 2: Create disk_check_cron.sh and extend watcher.sh** - `fe17c24` (feat)
3. **Task 3: Create test-recall.sh and test-disk-check.sh** - `aa9e7cc` (test)

## Files Created/Modified

- `modelstore/lib/notify.sh` — notify_user() with DBUS injection + alerts.log fallback
- `modelstore/cmd/recall.sh` — synchronous recall with fuser guard, state file, usage reset, audit logging
- `modelstore/cron/disk_check_cron.sh` — 98% threshold check, marker suppression, notify + audit
- `modelstore/hooks/watcher.sh` — extended with cold symlink detection and auto-recall trigger in watch_inotify()
- `modelstore/test/test-recall.sh` — 12 tests for RECL-01, RECL-02, RECL-03
- `modelstore/test/test-disk-check.sh` — 9 tests for SAFE-03, SAFE-04

## Decisions Made

- Test RECL-03 launcher_hook sets `COLD_PATH` directly from `$TMP/cold` instead of calling `load_config` — avoids reading the real system config when test runs in a temp HOME
- `check_disk_threshold` inlined in test-disk-check.sh (same pattern as test-watcher.sh for ms_track_usage) — allows `df` and `notify_user` to be mocked as shell functions without subprocess complications

## Deviations from Plan

None - plan executed exactly as written. The one deviation found during testing (COLD_PATH read from real system config) was in test infrastructure, not production code, and was fixed inline during the test task.

## Issues Encountered

- test-recall.sh Test 7 (launcher_hook) initially failed because `load_config` reads the real system config (`/home/robert_li/.modelstore/config.json`) when libs are sourced with the real `HOME`, returning the real `COLD_PATH` (`/media/robert_li/modelstore-1tb/modelstore`) instead of the test temp path. Fixed by setting `COLD_PATH="$TMP/cold"` directly without calling `load_config` — consistent with the established pattern (STATE.md decision) for tests needing env vars.

## User Setup Required

None - no external service configuration required. DBUS notification will work on any Ubuntu 22+ system with GNOME; alerts.log fallback handles headless environments.

## Next Phase Readiness

- Recall pipeline complete: `modelstore recall <model>` can be wired up in Phase 4 CLI dispatcher
- Both hot and cold drives monitored for fullness with actionable desktop notifications
- All 5 phase requirements (RECL-01, RECL-02, RECL-03, SAFE-03, SAFE-04) implemented and tested
- No blockers for Phase 4

---
*Phase: 03-migration-recall-and-safety*
*Completed: 2026-03-21*
