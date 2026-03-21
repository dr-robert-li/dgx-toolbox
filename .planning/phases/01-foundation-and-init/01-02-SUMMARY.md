---
phase: 01-foundation-and-init
plan: 02
subsystem: init
tags: [bash, gum, lsblk, findmnt, crontab, jq, huggingface, ollama]

# Dependency graph
requires:
  - phase: 01-foundation-and-init/01-01
    provides: lib/config.sh (write_config, backup_config_if_exists, config_read), lib/common.sh (validate_cold_fs, ms_log, ms_die)
provides:
  - modelstore/cmd/init.sh — Interactive TUI wizard for first-time setup and reinit
  - modelstore/test/test-init.sh — Integration tests for init functions (14 tests)
  - modelstore/test/test-fs-validation.sh — Filesystem type acceptance/rejection tests (8 tests)
  - ~/.modelstore/config.json — User config written by init wizard (verified on real DGX)
affects:
  - 01-03 (if any)
  - 02-migration (depends on config.json schema, cold_path, hot_hf_path, hot_ollama_path)
  - 03-cron (cron entries point to cron/ scripts; install_cron() skips gracefully until Phase 3)
  - all future phases (load_config depends on config.json produced here)

# Tech tracking
tech-stack:
  added: [gum (optional Charm TUI), numfmt, findmnt, lsblk, ollama /api/tags, HF scan_cache_dir API]
  patterns:
    - "BASH_SOURCE guard: define all functions + main(), call main() only when script is executed not sourced"
    - "Dual-path UI: gum TUI when available, read -p fallback always works"
    - "API-first detection: use CLI tool APIs (ollama show, curl /api/tags) as primary, filesystem scan as fallback"
    - "Graceful skip: cron install checks for script existence, skips with warning instead of failing"
    - "findmnt -l list mode: avoids tree-drawing characters that break gum choose parsing"

key-files:
  created:
    - modelstore/cmd/init.sh
    - modelstore/test/test-init.sh
    - modelstore/test/test-fs-validation.sh
  modified:
    - modelstore/test/run-all.sh
    - modelstore/lib/common.sh

key-decisions:
  - "Hot paths auto-detected from APIs (HF Python API, Ollama /api/tags) rather than user-entered — removes a class of user errors"
  - "Ollama path derived from `ollama show` blob path to handle system service installs at /usr/share/ollama/.ollama/models"
  - "validate_cold_fs extended to accept network/cloud mounts (nfs, nfs4, cifs, fuse.sshfs, fuse.rclone, fuse.s3fs, fuse.gcsfuse)"
  - "Cron install skips gracefully if Phase 3 scripts not yet present — init is safe to run before Phase 3"
  - "BASH_SOURCE guard enables sourcing init.sh in tests without triggering interactive prompts"

patterns-established:
  - "API-first detection with filesystem fallback: use tool APIs before walking directories"
  - "Dual-path TUI: GUM_AVAILABLE flag controls gum vs read-p branch; both paths must work"
  - "Graceful skip with warning for future-phase dependencies (cron scripts)"

requirements-completed: [INIT-01, INIT-02, INIT-03, INIT-04, INIT-07, INIT-08]

# Metrics
duration: ~45min
completed: 2026-03-21
---

# Phase 1 Plan 02: Init Wizard Summary

**Interactive modelstore init wizard with gum TUI/read-p fallback, API-first hot-path detection (HF + Ollama), ext4/xfs/btrfs/NFS cold drive selection with exFAT rejection, and config.json verified on real DGX with HF (2.8G) and Ollama (nemotron-cascade-2 24GB) model scan.**

## Performance

- **Duration:** ~45 min
- **Started:** 2026-03-21T00:11:00Z (approx)
- **Completed:** 2026-03-21T10:46:57Z
- **Tasks:** 3 (including human-verify checkpoint)
- **Files modified:** 5

## Accomplishments

- Built 365-line `cmd/init.sh` interactive wizard with gum TUI and read-p fallback covering all init flows (first-run, reinit with backup, migration)
- Hot paths auto-detected via HF Python cache API and Ollama `/api/tags` — confirmed correct on real DGX (HF at `~/.cache/huggingface/hub`, Ollama at `/usr/share/ollama/.ollama/models`)
- Cold drive selected via `gum choose` from `findmnt -l` output — exFAT rejected, ext4 accepted; `validate_cold_fs` extended to accept network/cloud FUSE mounts
- Model scan table displays HF cache entries (2.8G) and Ollama models (nemotron-cascade-2 24GB) with human-readable sizes via `numfmt`
- 22 tests across two new test files (8 filesystem, 14 init integration) — all pass via `run-all.sh`
- User verified config.json written correctly with all expected fields; cron install gracefully skips until Phase 3 scripts exist

## Task Commits

Each task was committed atomically:

1. **Task 1: Create cmd/init.sh with full wizard flow** - `54031d4` (feat)
2. **Task 2: Create init tests and update test runner** - `f1931e1` (feat)
3. **Task 3: Verify init wizard works interactively** - `feaac12` (fix — post-checkpoint fixes committed after human verify)

## Files Created/Modified

- `modelstore/cmd/init.sh` — 365+ line interactive wizard (gum/read-p dual-path, hot-path API detection, cold drive selection, model scan, config write, cron install, reinit)
- `modelstore/test/test-init.sh` — 14 integration tests (scan_hf_models, config round-trip, cold dir structure, backup)
- `modelstore/test/test-fs-validation.sh` — 8 tests (ext4/xfs/btrfs accept, exfat/vfat/ntfs/unmounted reject, symlink error message)
- `modelstore/test/run-all.sh` — Added test-fs-validation.sh and test-init.sh to sequential runner
- `modelstore/lib/common.sh` — Extended `validate_cold_fs` to accept NFS/CIFS/FUSE mount types

## Decisions Made

- **API-first hot path detection:** HF path from `python3 -c "from huggingface_hub import constants; print(constants.HF_HUB_CACHE)"` and Ollama path from `ollama show` blob path. Eliminates user-entry errors and handles non-standard install locations (system service at `/usr/share/ollama/`).
- **validate_cold_fs extended for network mounts:** Added nfs, nfs4, cifs, fuse.sshfs, fuse.rclone, fuse.s3fs, fuse.gcsfuse — users may cold-store on NAS or cloud bucket mounts.
- **Cron install skips gracefully:** `install_cron()` checks for cron script existence before adding crontab entries; emits a warning and continues. Makes init safe to run before Phase 3.
- **BASH_SOURCE guard in init.sh:** `[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"` allows tests to source the file and call individual functions without triggering the interactive wizard.
- **findmnt -l (list mode):** Tree output mode produced box-drawing characters that broke `gum choose`; `-l` produces clean one-entry-per-line output.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Hot paths were user-prompted instead of auto-detected**
- **Found during:** Task 3 (human verify checkpoint)
- **Issue:** Plan specified user confirmation of detected paths, but auto-detection code was not using APIs — was prompting user to enter paths manually
- **Fix:** Replaced prompt_input for hot paths with API-based detection (HF Python constants, `ollama show` blob path parsing)
- **Files modified:** modelstore/cmd/init.sh
- **Verification:** User confirmed hot paths displayed correctly without prompting on DGX
- **Committed in:** feaac12

**2. [Rule 1 - Bug] findmnt in tree mode produced characters incompatible with gum choose**
- **Found during:** Task 3 (human verify checkpoint)
- **Issue:** `findmnt` default output uses box-drawing tree characters; gum choose showed corrupted entries
- **Fix:** Added `-l` flag for list mode output
- **Files modified:** modelstore/cmd/init.sh
- **Verification:** Drive selection list showed clean mount point entries
- **Committed in:** feaac12

**3. [Rule 2 - Missing Critical] validate_cold_fs rejected valid network/cloud mounts**
- **Found during:** Task 3 (human verify checkpoint user context)
- **Issue:** validate_cold_fs only accepted ext4/xfs/btrfs — would reject NFS NAS or cloud FUSE mounts that are perfectly valid for cold storage
- **Fix:** Extended accepted types to include nfs, nfs4, cifs, fuse.sshfs, fuse.rclone, fuse.s3fs, fuse.gcsfuse
- **Files modified:** modelstore/lib/common.sh, modelstore/cmd/init.sh
- **Verification:** Acceptance list updated; rejection still applies to exfat/vfat/ntfs
- **Committed in:** feaac12

**4. [Rule 3 - Blocking] Cron install failed when Phase 3 scripts don't exist yet**
- **Found during:** Task 3 (human verify checkpoint — user reported "cron gracefully skipped")
- **Issue:** `install_cron()` referenced cron/migrate_cron.sh and cron/disk_check_cron.sh which don't exist until Phase 3; would confuse users
- **Fix:** Added existence check before adding crontab entry; emits `[WARN] cron script not found — skipping` and continues
- **Files modified:** modelstore/cmd/init.sh
- **Verification:** User confirmed graceful skip during interactive verify
- **Committed in:** feaac12

---

**Total deviations:** 4 auto-fixed (2 bugs, 1 missing critical, 1 blocking)
**Impact on plan:** All fixes required for correct behavior on the actual DGX environment. No scope creep — each fix directly enabled init to complete successfully.

## Issues Encountered

- Ollama system service install path (`/usr/share/ollama/.ollama/models`) differs from the default user path (`~/.ollama/models`) — API-based detection via `ollama show` resolved this cleanly by parsing the blob path from the response.
- HF Python API required `huggingface_hub` to be importable; fallback to `${HF_HOME:-${HOME}/.cache/huggingface}/hub` used when Python import fails.

## User Setup Required

None — no external service configuration required. Config is written to `~/.modelstore/config.json` by the wizard itself.

## Next Phase Readiness

- `~/.modelstore/config.json` written and verified — all Phase 2+ scripts can `load_config` immediately
- Cold drive directory structure (`${COLD_PATH}/huggingface/hub`, `${COLD_PATH}/ollama/models`) created and ready for migration scripts
- `validate_cold_fs` extended for network mounts — Phase 2 migration scripts inherit this without changes
- Cron slot reserved (hour stored in config) — Phase 3 cron scripts will be picked up by re-running init or by adding entries manually
- Known blocker carried forward: Ollama manifest JSON schema field paths need verification with `cat ~/.ollama/models/manifests/...` before writing `ollama_adapter.sh` in Phase 2

---
*Phase: 01-foundation-and-init*
*Completed: 2026-03-21*
