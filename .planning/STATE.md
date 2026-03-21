---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
status: Defining requirements
stopped_at: Completed 04-02-PLAN.md (directory reorganization + TTY guards + docs)
last_updated: "2026-03-21T22:17:38.032Z"
last_activity: 2026-03-22 — Milestone v1.1 started
progress:
  total_phases: 4
  completed_phases: 4
  total_plans: 8
  completed_plans: 8
  percent: 0
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-22)

**Core value:** Models are always accessible regardless of which tier they're on while the hot drive never fills up with stale models.
**Current focus:** v1.1 Safety Harness — defining requirements

## Current Position

Phase: Not started (defining requirements)
Plan: —
Status: Defining requirements
Last activity: 2026-03-22 — Milestone v1.1 started

Progress: [░░░░░░░░░░] 0%

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- Symlinks over hard links (cross-filesystem requirement)
- Configurable hot/cold at init (user may swap drives later)
- Bash only, no Python (host execution, minimize dependencies)
- Single modelstore CLI + individual cron scripts (interactive vs headless separation)
- PASS=$((PASS+1)) not ((PASS++)) in bash test scripts with set -e (arithmetic expansion returns exit code 1 when result is 0)
- validate_cold_fs returns 1 not exit 1 (callers handle rejection gracefully)
- No bats dependency — inline bash assertion pattern runs everywhere
- [Phase 01-foundation-and-init]: Hot paths auto-detected via HF Python API and Ollama /api/tags rather than user-entered — eliminates user-entry errors and handles non-standard install paths
- [Phase 01-foundation-and-init]: validate_cold_fs extended to accept network/cloud mounts (nfs, nfs4, cifs, fuse.sshfs, fuse.rclone, fuse.s3fs, fuse.gcsfuse) for NAS/cloud cold storage
- [Phase 01-foundation-and-init]: Cron install skips gracefully if Phase 3 scripts not yet present — init safe to run before Phase 3
- [Phase 02-adapters-and-usage-tracking]: hf_migrate_model symlink-already-migrated check placed BEFORE mount/space guards (idempotent re-run works without cold drive mounted)
- [Phase 02-adapters-and-usage-tracking]: Ollama migrate/recall stubs defer actual ollama cp/rm to Phase 3 — guards are complete (SAFE-06 block, SAFE-01 mount, SAFE-02 space)
- [Phase 02-adapters-and-usage-tracking]: Test comment strings avoid grep pattern words (sudo, set -e) to keep acceptance criteria grep checks from matching comments
- [Phase 02-adapters-and-usage-tracking]: Function definitions copied inline in test file rather than sourcing watcher.sh — avoids BASH_SOURCE path resolution issues with process substitution
- [Phase 02-adapters-and-usage-tracking]: ms_track_usage debounce reads last timestamp before acquiring flock to avoid contention on frequent access events
- [Phase 02-adapters-and-usage-tracking]: Daemon uses wait -n with fallback to wait so either watcher subprocess exiting terminates the parent daemon
- [Phase 03-migration-recall-and-safety]: Ollama recall derives cold_base by following hot blob symlink via readlink — more robust than requiring cold_base as parameter
- [Phase 03-migration-recall-and-safety]: cron_output unbound variable with set -uo pipefail fixed by tee to temp file instead of command substitution with background process
- [Phase 03-migration-recall-and-safety]: find_stale_hf_models checks symlink status in both usage.json and directory walk paths to avoid re-migrating already-migrated models
- [Phase 03-migration-recall-and-safety]: Test RECL-03 launcher_hook sets COLD_PATH directly ($TMP/cold) instead of calling load_config to avoid reading real system config
- [Phase 03-migration-recall-and-safety]: check_disk_threshold inlined in test-disk-check.sh to allow df/notify_user mocking as shell functions without subprocess complications
- [Phase 04-cli-status-revert-and-docs]: status.sh uses find -maxdepth 1 (not hf_list_models Python API) to detect all tiers including BROKEN dangling symlinks
- [Phase 04-cli-status-revert-and-docs]: revert.sh completed_models JSON array in op_state.json enables interrupt-safe multi-model tracking via _append_completed/_is_completed helpers
- [Phase 04-cli-status-revert-and-docs]: test-revert.sh mock pattern: generate mock_cmd/revert.sh with inline check_cold_mounted override + tail -n +21 for body (common.sh uses mountpoint -q which fails in temp dirs)
- [Phase 04-cli-status-revert-and-docs]: rsync_flags variable approach for TTY guard in adapter rsync calls — cleaner than inline substitution
- [Phase 04-cli-status-revert-and-docs]: modelstore.sh stays in root alongside status.sh and lib.sh (not moved to subdirectory)

### Pending Todos

None yet.

### Blockers/Concerns

- Phase 2: Ollama manifest JSON schema field paths not fully specified in research — verify with `cat ~/.ollama/models/manifests/...` on actual DGX before writing ollama_adapter.sh
- Phase 3: DBUS session address injection for notify-send from cron is MEDIUM confidence on aarch64 — test on actual machine before committing approach
- Phase 4: Revert state file JSON schema not yet specified — design during Phase 4 planning before writing revert.sh

## Session Continuity

Last session: 2026-03-21T22:17:38.029Z
Stopped at: Completed 04-02-PLAN.md (directory reorganization + TTY guards + docs)
Resume file: None
