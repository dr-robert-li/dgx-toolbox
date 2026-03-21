---
phase: 01-foundation-and-init
verified: 2026-03-21T12:00:00Z
status: human_needed
score: 12/12 must-haves verified (automated)
re_verification: false
human_verification:
  - test: "Run ./modelstore.sh init on the actual DGX machine"
    expected: "lsblk output shows drives, gum TUI presents mount point list, exFAT drive rejected with symlink error, ext4 drive accepted, model scan table displays HF and Ollama models with sizes, config.json written to ~/.modelstore/config.json with user-entered values"
    why_human: "Interactive TUI wizard cannot be verified headlessly; requires a real terminal with drives attached"
  - test: "Run ./modelstore.sh init a second time after first init"
    expected: "Detects existing config, backs it up, shows existing models with sizes, presents reinit action menu (migrate / recall_first / cancel)"
    why_human: "Reinit flow is interactive; cannot verify the prompt-and-response cycle programmatically"
  - test: "Attempt to select an exFAT-formatted drive during init"
    expected: "validate_cold_fs prints error explaining symlinks are not supported on exFAT, suggests mkfs.ext4, wizard aborts cleanly"
    why_human: "Requires a real exFAT-formatted block device to be present on the machine"
  - test: "Verify crontab entries are installed"
    expected: "crontab -l | grep modelstore shows no entries (cron skips gracefully until Phase 3 scripts exist) with a warning logged to stderr"
    why_human: "Crontab state is user-session-specific and cannot be queried from the test harness"
  - test: "Verify ~/.modelstore/config.json fields match what was entered during init"
    expected: "jq . ~/.modelstore/config.json shows version:1, correct hot_hf_path, hot_ollama_path, cold_path, retention_days, cron_hour, backup_retention_days, created_at, updated_at"
    why_human: "Requires having run init interactively; the file may already exist on the DGX from the human verify checkpoint (Task 3 in Plan 02) that was confirmed during plan execution"
---

# Phase 1: Foundation and Init — Verification Report

**Phase Goal:** The project structure exists with a working config system, shared safety library, and an interactive init wizard that produces a validated config file all other scripts depend on
**Verified:** 2026-03-21T12:00:00Z
**Status:** human_needed (all automated checks pass; interactive wizard flow requires human confirmation)
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths (from ROADMAP.md Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | User can run `modelstore init` and be guided through selecting hot/cold paths with a filesystem tree preview, confirming before any directories are created | ? HUMAN | `lsblk` + `findmnt` + `gum choose` / `prompt_choose` all present in init.sh (lines 360-393); confirmation gate at line 390; cannot verify interactive flow headlessly |
| 2 | Init rejects a cold drive formatted as exFAT and requires ext4/xfs, explaining why | ✓ VERIFIED | `validate_cold_fs` in common.sh (lines 66-90) rejects exfat/vfat/ntfs with symlink explanation; `validate_cold_fs` called in init.sh line 378; 8 automated tests pass (test-fs-validation.sh) |
| 3 | After init, a config file exists on disk with retention period, cron schedule, and drive paths — all values match what the user entered | ? HUMAN | `write_config` in config.sh (lines 51-78) writes full JSON via jq -n with all fields; called from init.sh line 441; config round-trip verified by 14 automated tests; actual ~/.modelstore/config.json existence requires human verification |
| 4 | User can run `modelstore init` again (reinit) to reconfigure drives, and existing model locations are shown with sizes before any migration begins | ? HUMAN | `config_exists` check + `backup_config_if_exists` + `show_existing_models` before reinit menu confirmed in init.sh lines 277-303; requires interactive run to confirm |
| 5 | Init scans and displays all existing HuggingFace and Ollama models with their sizes so the user sees what will be managed | ✓ VERIFIED | `scan_hf_models` (lines 90-153) and `scan_ollama_models` (lines 157-218) both implemented with API-first + filesystem fallback; formatted table with numfmt; 5 automated tests for scan_hf_models pass |

**Automated score:** 12/12 must-haves verified (all artifacts, key links, tests); 5 Success Criteria truths with 2 fully verified automated, 3 requiring human confirmation for the interactive layer.

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `modelstore.sh` | CLI entry point thin router | ✓ VERIFIED | 43 lines; `set -euo pipefail`; sources both libs; `exec "${MODELSTORE_CMD}/init.sh"` for init subcommand; executable |
| `modelstore/lib/config.sh` | JSON config read/write helpers | ✓ VERIFIED | 103 lines; exports config_exists, config_read, load_config, write_config, backup_config_if_exists; jq -n write, chmod 600; no side effects on source |
| `modelstore/lib/common.sh` | Logging, mount check, space check, fs validation | ✓ VERIFIED | 91 lines; exports ms_log, ms_die, check_cold_mounted, check_space, validate_cold_fs; sources lib.sh via BASH_SOURCE; mountpoint -q (not test -d); findmnt for fs type |
| `modelstore/test/smoke.sh` | Function existence sanity checks | ✓ VERIFIED | 13 assertions; all pass; no external dependency |
| `modelstore/test/test-config.sh` | Config read/write round-trip tests | ✓ VERIFIED | 14 assertions; all pass; uses temp MODELSTORE_CONFIG override |
| `modelstore/test/test-common.sh` | Filesystem validation and logging tests | ✓ VERIFIED | 11 assertions; all pass; mocks findmnt via bash function override |
| `modelstore/test/run-all.sh` | Test suite runner | ✓ VERIFIED | Runs all 5 test scripts sequentially; exits non-zero on failure; all pass |
| `modelstore/cmd/init.sh` | Interactive init wizard (gum/read-p fallback) | ✓ VERIFIED | 481 lines (min_lines: 200 exceeded); BASH_SOURCE guard; dual-path TUI; all key functions present and called |
| `modelstore/test/test-init.sh` | Init integration tests | ✓ VERIFIED | 14 assertions; all pass; tests scan_hf_models, config round-trip, cold dir structure, backup |
| `modelstore/test/test-fs-validation.sh` | Filesystem type rejection tests | ✓ VERIFIED | 8 assertions; all pass; ext4/xfs/btrfs accepted; exfat/vfat/ntfs rejected |

**Directory structure:** `modelstore/lib/`, `modelstore/cmd/`, `modelstore/hooks/`, `modelstore/test/fixtures/` — all present.

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `modelstore.sh` | `modelstore/lib/common.sh` | `source` | ✓ WIRED | Line 11: `source "${MODELSTORE_LIB}/common.sh"` |
| `modelstore.sh` | `modelstore/lib/config.sh` | `source` | ✓ WIRED | Line 13: `source "${MODELSTORE_LIB}/config.sh"` |
| `modelstore/lib/common.sh` | `lib.sh` | `source` via BASH_SOURCE | ✓ WIRED | Lines 6-7: `_TOOLBOX_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../" && pwd)/lib.sh"` then `source "$_TOOLBOX_LIB"` |
| `modelstore/lib/config.sh` | `~/.modelstore/config.json` | `jq` read/write via `MODELSTORE_CONFIG` | ✓ WIRED | `jq -r "$key" "$MODELSTORE_CONFIG"` (read) and `jq -n ... > "$MODELSTORE_CONFIG"` (write) both present |
| `modelstore/cmd/init.sh` | `modelstore/lib/config.sh` | `source` + `write_config` call | ✓ WIRED | Lines 8-9: sources config.sh; line 441: `write_config "$HOT_HF_PATH" ...` |
| `modelstore/cmd/init.sh` | `modelstore/lib/common.sh` | `source` + `validate_cold_fs` call | ✓ WIRED | Lines 8: sources common.sh; line 378: `if ! validate_cold_fs "$COLD_MOUNT"` |
| `modelstore.sh` | `modelstore/cmd/init.sh` | `exec` dispatch | ✓ WIRED | Line 19: `init) exec "${MODELSTORE_CMD}/init.sh" "$@" ;;` |

All 7 key links verified as WIRED with actual code evidence.

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| INIT-01 | 01-02 | Interactive init wizard with filesystem tree and drive selection | ✓ SATISFIED | `lsblk` (line 360) + `findmnt -l` (line 367) + `gum choose` / `prompt_choose` (line 371/374) in init.sh |
| INIT-02 | 01-02 | Init creates directory structure on both drives with user confirmation | ✓ SATISFIED | `prompt_confirm` gate (line 427) before `mkdir -p` for `${HOME}/.modelstore/usage`, `${COLD_PATH}/huggingface/hub`, `${COLD_PATH}/ollama/models` (lines 433-437) |
| INIT-03 | 01-02 | User can configure retention period (default 14 days) during init | ✓ SATISFIED | `prompt_input "Hot storage retention policy (days)" "14" RETENTION_DAYS` (line 398); integer validation; passed to `write_config` |
| INIT-04 | 01-02 | User can configure cron schedule (default 2 AM) during init | ✓ SATISFIED | `prompt_input "Cron hour (0-23, daily migration)" "2" CRON_HOUR` (line 403); range validation; `install_cron "$CRON_HOUR"` (line 446) |
| INIT-05 | 01-01 | Init persists all settings to a config file on disk | ✓ SATISFIED | `write_config` in config.sh writes full JSON schema (version, all paths, retention_days, cron_hour, backup_retention_days, timestamps) to `~/.modelstore/config.json` with `chmod 600`; 14 automated tests confirm round-trip |
| INIT-06 | 01-01, 01-02 | Init validates cold drive filesystem (rejects exFAT, requires ext4/xfs) | ✓ SATISFIED | `validate_cold_fs` rejects exfat/vfat/ntfs (returns 1 with error), accepts ext4/xfs/btrfs/nfs/cifs/fuse.*; 8 dedicated tests pass |
| INIT-07 | 01-02 | Init scans existing models and shows what's where with sizes | ✓ SATISFIED | `scan_hf_models` (API-first via huggingface_hub Python, fallback dir scan) and `scan_ollama_models` (API-first via /api/tags, fallback manifest scan); formatted table with `numfmt`; called in `show_existing_models` during wizard flow |
| INIT-08 | 01-02 | User can reinitialize to different drives with progress bars for migration and garbage collection on old paths | ✓ SATISFIED | `config_exists` reinit check (line 277); `backup_config_if_exists` (line 278); `REINIT_ACTION` menu; `rsync -av --info=progress2` for migration (line 454); `rm -rf "${old_cold}"` cleanup with `prompt_confirm` gate (lines 456-463) |

All 8 Phase 1 requirements satisfied. Requirements INIT-01 through INIT-08 are correctly mapped to Phase 1 in REQUIREMENTS.md. No orphaned requirements found.

### Anti-Patterns Found

No anti-patterns detected across all modified files:
- No TODO/FIXME/PLACEHOLDER comments
- No empty return stubs
- No console-only implementations
- No stub functions

### Human Verification Required

#### 1. Interactive Init Wizard — Full Flow

**Test:** Run `./modelstore.sh init` in a terminal on the DGX machine (with the modelstore-1tb drive connected)
**Expected:** lsblk shows drives; gum presents mount list or read-p fallback works; modelstore-1tb (ext4) is accepted; exFAT backup-256g (if present) is rejected with symlink explanation; HF models (~2.8G) and Ollama models (nemotron-cascade-2 ~24GB) appear in the scan table; `~/.modelstore/config.json` is written with correct values matching entries
**Why human:** TUI wizard requires a real TTY; lsblk/findmnt output depends on the physical drives present; Ollama /api/tags requires the Ollama daemon to be running

#### 2. Reinit Flow

**Test:** Run `./modelstore.sh init` a second time after a successful first init
**Expected:** "Existing config found. Cold store: /media/..." printed; existing models displayed with sizes; reinit menu with "Migrate", "Recall first", "Cancel" options appears; selecting "Cancel" exits cleanly
**Why human:** Multi-prompt interactive sequence that requires a real terminal session

#### 3. ExFAT Rejection in Practice

**Test:** If the backup-256g (exFAT) drive is mounted, attempt to select it as the cold drive
**Expected:** `validate_cold_fs` prints the exFAT error explaining symlinks require a Linux filesystem, wizard aborts with `ms_die`
**Why human:** Requires an exFAT-formatted block device to be mounted on the test machine

#### 4. Crontab State

**Test:** After running init, check `crontab -l | grep modelstore`
**Expected:** No modelstore cron entries (Phase 3 scripts not yet created) and `[modelstore] Cron scripts not yet installed` warning was emitted during init
**Why human:** Crontab is per-user state that cannot be read from the test harness

#### 5. Config.json Field Verification

**Test:** `jq . ~/.modelstore/config.json`
**Expected:** All fields present: version=1, hot_hf_path, hot_ollama_path, cold_path, retention_days, cron_hour, backup_retention_days, created_at, updated_at — all matching what was entered during init
**Why human:** Requires the file to have been written by a real init run; note that per the SUMMARY.md (Task 3 human verify checkpoint in Plan 02), the user already confirmed this during plan execution on the actual DGX

### Test Suite Results

All 60 automated assertions pass across 5 test files:

| Test File | Assertions | Result |
|-----------|-----------|--------|
| smoke.sh | 13 | ✓ All pass |
| test-config.sh | 14 | ✓ All pass |
| test-common.sh | 11 | ✓ All pass |
| test-fs-validation.sh | 8 | ✓ All pass |
| test-init.sh | 14 | ✓ All pass |
| **Total** | **60** | **✓ 60/60 pass** |

### Summary

Phase 1 is fully implemented and all automated checks pass. The foundation is solid:

- **Config system:** `config.sh` provides a complete JSON read/write layer via jq. All 5 functions work correctly and are tested. Config round-trips cleanly with correct types (int vs string).
- **Safety library:** `common.sh` provides logging, mount verification (mountpoint -q, not test -d), space checking with 10% margin, and filesystem type validation. Accepts ext4/xfs/btrfs/nfs/cifs/fuse.*; rejects exfat/vfat/ntfs with clear error.
- **CLI router:** `modelstore.sh` is a thin exec-based router that sources libs and dispatches to `cmd/*.sh` scripts. Strict mode enabled. All 5 subcommands wired.
- **Init wizard:** `cmd/init.sh` is 481 lines with dual-path TUI (gum + read-p fallback), API-first hot-path detection, cold drive selection with filesystem validation, model scan table, config write, cron install (with graceful skip for Phase 3 dependency), and reinit support with backup and rsync migration.
- **Test infrastructure:** 60 assertions across 5 test files; all pass in under 5 seconds via run-all.sh.

The 3 human verification items are all related to the interactive TUI layer — the underlying logic is fully tested. Per the Plan 02 SUMMARY.md, a human verify checkpoint (Task 3) was completed during plan execution and the user confirmed the wizard worked correctly on the DGX, config.json was written correctly, and cron gracefully skipped.

---

_Verified: 2026-03-21T12:00:00Z_
_Verifier: Claude (gsd-verifier)_
