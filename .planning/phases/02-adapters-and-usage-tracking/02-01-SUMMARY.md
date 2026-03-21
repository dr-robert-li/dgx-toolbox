---
phase: 02-adapters-and-usage-tracking
plan: 01
subsystem: storage-adapters
tags: [bash, rsync, symlinks, huggingface, ollama, curl, jq, mountpoint, safety-guards]

requires:
  - phase: 01-foundation-and-init
    provides: "common.sh (check_cold_mounted, check_space, ms_die, ms_log), config.sh (load_config, HOT_HF_PATH, COLD_PATH)"

provides:
  - "hf_adapter.sh: 5-function HF storage adapter (list, size, path, migrate with rsync+symlink, recall)"
  - "ollama_adapter.sh: 6-function Ollama API-only adapter (server check, list, size, path, migrate stub, recall stub)"
  - "test-hf-adapter.sh: 12 assertions covering all HF adapter operations and SAFE-01/02 guards"
  - "test-ollama-adapter.sh: 15 assertions covering all Ollama adapter operations and SAFE-01/02/06 guards"

affects:
  - 02-02-watcher
  - 03-migration-and-recall

tech-stack:
  added: []
  patterns:
    - "Bash function mock pattern: define bash function with same name as system command to override in test scope"
    - "rsync --remove-source-files for cross-filesystem atomic moves (not cp+rm)"
    - "mv -T for atomic symlink replacement (atomic rename(2) syscall)"
    - "Adapter symlink-already-migrated check before mount/space guards (early exit, no cold drive required)"
    - "curl call counter mock: differentiate server-check curl calls from data-fetch curl calls in tests"

key-files:
  created:
    - modelstore/lib/hf_adapter.sh
    - modelstore/lib/ollama_adapter.sh
    - modelstore/test/test-hf-adapter.sh
    - modelstore/test/test-ollama-adapter.sh
  modified:
    - modelstore/test/run-all.sh

key-decisions:
  - "Symlink-already-migrated check placed BEFORE mount/space guards in hf_migrate_model (allows idempotent re-runs without cold drive mounted)"
  - "Ollama adapter is pure stub for migrate/recall with correct guard structure (Phase 3 implements ollama cp + ollama rm)"
  - "Test comment strings avoided grep pattern words (sudo, set -e) to keep acceptance criteria grep checks clean"

patterns-established:
  - "Adapter guard order for HF: symlink-check first, then mount, then space"
  - "Adapter guard order for Ollama: server-block first, then mount, then space"
  - "All adapter function mocks use bash function overrides (no external mock frameworks)"

requirements-completed: [SAFE-01, SAFE-02, SAFE-06]

duration: 6min
completed: 2026-03-21
---

# Phase 2 Plan 1: HF and Ollama Storage Adapters Summary

**HF adapter with rsync+atomic-symlink migrate/recall and Ollama API-only adapter with SAFE-06 server block, both with 27 assertions covering SAFE-01/02/06 guard behaviors**

## Performance

- **Duration:** 6 min
- **Started:** 2026-03-21T01:52:36Z
- **Completed:** 2026-03-21T01:59:07Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments

- HF adapter (`hf_adapter.sh`): 5 functions using filesystem ops — list via Python API with directory-walk fallback, size via `du -sb`, migrate via `rsync --remove-source-files` + atomic `ln -s`/`mv -T` symlink swap, recall via reverse rsync + symlink removal
- Ollama adapter (`ollama_adapter.sh`): 6 functions using HTTP API only — server check via `systemctl is-active` + curl fallback, list/size via `/api/tags`, migrate/recall as Phase 3 stubs with full guard structure (SAFE-06 server block, SAFE-01 mount check, SAFE-02 space check)
- 27 total test assertions: 12 for HF adapter (SAFE-01/02, symlink skip, migration success, recall skip), 15 for Ollama adapter (SAFE-06 detection, all three migrate guard paths)
- Full test suite passes: 74 assertions across 7 test files

## Task Commits

1. **Task 1: Create hf_adapter.sh and ollama_adapter.sh** - `28b5a73` (feat)
2. **Task 2: Add test files and update run-all.sh** - `d0ba92a` (feat)

## Files Created/Modified

- `modelstore/lib/hf_adapter.sh` — HF storage adapter: hf_list_models, hf_get_model_size, hf_get_model_path, hf_migrate_model, hf_recall_model
- `modelstore/lib/ollama_adapter.sh` — Ollama API adapter: ollama_check_server, ollama_list_models, ollama_get_model_size, ollama_get_model_path, ollama_migrate_model (stub), ollama_recall_model (stub)
- `modelstore/test/test-hf-adapter.sh` — 12 assertions covering all HF adapter operations
- `modelstore/test/test-ollama-adapter.sh` — 15 assertions covering all Ollama adapter operations
- `modelstore/test/run-all.sh` — Added both new test files to suite

## Decisions Made

- **Symlink check before mount/space guards in hf_migrate_model:** Plan spec listed symlink check after guards, but logically it should be first (idempotent re-run should not require cold drive mounted). Moved check to top of function.
- **Ollama migrate/recall as stubs:** Phase 2 provides correct guard structure; actual `ollama cp`/`ollama rm` implementation deferred to Phase 3 when `ollama cp` destination path behavior is verified on real DGX.
- **Test comment phrasing:** Comments in lib files avoided the words "sudo" and "set -e" to prevent grep-based acceptance criteria from matching comments instead of actual code.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Reordered symlink-already-migrated check before mount/space guards**
- **Found during:** Task 2 (test-hf-adapter.sh Test 7 failure)
- **Issue:** Plan's action spec placed `[[ -L "$model_id" ]]` AFTER `check_cold_mounted` and `check_space`. Test 7 called `hf_migrate_model` with a symlink but no cold mount, expected return 0 (skip), but `check_cold_mounted` fired first and exited non-zero via `ms_die`.
- **Fix:** Moved the symlink-already-migrated early-exit check to the top of `hf_migrate_model`, before the mount and space guards. Correct semantics: if already migrated, nothing to do regardless of cold drive state.
- **Files modified:** `modelstore/lib/hf_adapter.sh`
- **Verification:** All 12 test-hf-adapter.sh assertions pass, including Test 7 (symlink skip) and Test 5 (mount check still fires for non-symlink paths)
- **Committed in:** d0ba92a (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 - bug: incorrect guard ordering from plan spec)
**Impact on plan:** Auto-fix improves idempotency — re-running migrate on already-migrated model works without cold drive mounted. No scope creep.

## Issues Encountered

- Test 9 (Ollama space check): `curl` mock returned success for all calls, causing `ollama_check_server` to think Ollama was running (blocking the migrate). Fixed by using a call counter within the curl mock: first call (server check) returns failure, subsequent calls (model size lookup) return mock JSON.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Both adapters ready for Phase 3 (migrate.sh and recall.sh will `source` them and call the 5/6 functions)
- Phase 3 must implement actual `ollama cp`/`ollama rm` in `ollama_migrate_model` and `ollama_recall_model` stubs
- Interface is stable: `hf_migrate_model <model_id> <cold_base>` and `ollama_migrate_model <model_name> <cold_base>` are the contracts
- Open blocker from STATE.md: verify `ollama cp` destination path behavior on actual DGX before Phase 3

---
*Phase: 02-adapters-and-usage-tracking*
*Completed: 2026-03-21*
