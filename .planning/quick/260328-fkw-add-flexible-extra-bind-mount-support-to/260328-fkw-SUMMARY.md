---
phase: quick
plan: 260328-fkw
subsystem: infra
tags: [bash, docker, containers, bind-mounts]

requires: []
provides:
  - "build_extra_mounts() in lib.sh: parses EXTRA_MOUNTS env var into -v flags"
  - "All 5 container scripts support EXTRA_MOUNTS for user-supplied extra bind mounts"
affects: [containers, lib.sh]

tech-stack:
  added: []
  patterns:
    - "EXTRA_MOUNTS=host:container,host2:container2 passed to any container script for ad-hoc mounts"
    - "Invalid mount specs skip with stderr warning rather than failing script"

key-files:
  created: []
  modified:
    - lib.sh
    - containers/unsloth-studio.sh
    - containers/unsloth-studio-sync.sh
    - containers/ngc-pytorch.sh
    - containers/ngc-jupyter.sh
    - containers/start-n8n.sh

key-decisions:
  - "IFS=',' loop over EXTRA_MOUNTS with IFS=' ' reset before echo to produce space-separated -v flags"
  - "$(build_extra_mounts) unquoted in docker run so bash word-splits the flags into separate arguments"
  - "Invalid specs (no colon, empty segments) warn to stderr and are skipped — no hard failure"

requirements-completed: []

duration: 10min
completed: 2026-03-28
---

# Quick Task 260328-fkw: Extra Bind Mount Support Summary

**`build_extra_mounts()` added to lib.sh and wired to all 5 container scripts via `EXTRA_MOUNTS` env var (comma-separated `host:container` pairs)**

## Performance

- **Duration:** ~10 min
- **Started:** 2026-03-28T00:00:00Z
- **Completed:** 2026-03-28T00:10:00Z
- **Tasks:** 1
- **Files modified:** 6

## Accomplishments

- Added `build_extra_mounts()` to `lib.sh` after `ensure_dirs()`: parses `EXTRA_MOUNTS` comma-separated mount specs into `-v host:container` flags; invalid specs (missing colon, empty segments) warn to stderr and are skipped; empty/unset `EXTRA_MOUNTS` returns nothing (backward compatible)
- Sourced `lib.sh` in `unsloth-studio.sh`, `unsloth-studio-sync.sh`, `ngc-pytorch.sh`, and `ngc-jupyter.sh` (previously not sourcing it) and added `$(build_extra_mounts)` after existing `-v` lines in each docker run command
- Added `$(build_extra_mounts)` to `start-n8n.sh` `create_n8n()` function (already sourced `lib.sh`)

## Task Commits

1. **Task 1: Add build_extra_mounts() to lib.sh and wire all container scripts** - `523ff20` (feat)

**Plan metadata:** pending docs commit

## Files Created/Modified

- `lib.sh` - Added `build_extra_mounts()` function after `ensure_dirs()`
- `containers/unsloth-studio.sh` - Added `source lib.sh`, added `$(build_extra_mounts)` in docker run
- `containers/unsloth-studio-sync.sh` - Added `source lib.sh`, added `$(build_extra_mounts)` in docker run
- `containers/ngc-pytorch.sh` - Added `source lib.sh`, added `$(build_extra_mounts)` in docker run
- `containers/ngc-jupyter.sh` - Added `source lib.sh`, added `$(build_extra_mounts)` in docker run
- `containers/start-n8n.sh` - Added `$(build_extra_mounts)` in `create_n8n()` docker run

## Decisions Made

- `IFS=','` is set for the for-loop split, then reset to `IFS=' '` before `echo "${mounts[*]}"` — otherwise the array join uses comma as separator, producing wrong output
- `$(build_extra_mounts)` must be unquoted in docker run so bash word-splits the space-separated `-v flags` into separate arguments

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed IFS contamination in build_extra_mounts() output**
- **Found during:** Task 1 verification
- **Issue:** Setting `local IFS=','` for loop iteration caused `echo "${mounts[*]}"` to join array elements with commas, producing `-v,/tmp/a:/mnt/a,-v,/tmp/b:/mnt/b` instead of `-v /tmp/a:/mnt/a -v /tmp/b:/mnt/b`
- **Fix:** Reset `IFS=' '` before the echo statement; `xargs` for whitespace trimming uses `$(IFS=' ' ; echo "$spec" | xargs)` to avoid IFS leakage
- **Files modified:** lib.sh
- **Verification:** All 3 plan verification tests pass: two-mount expansion, empty/unset, invalid-spec skip
- **Committed in:** 523ff20 (part of task commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 - bug in function output)
**Impact on plan:** Fix necessary for correctness. No scope creep.

## Issues Encountered

- Plan-provided function used `local IFS=','` scoped to the function — but `echo "${mounts[*]}"` at the end still runs within that IFS scope, so array join used comma. Fixed by resetting IFS before the echo.

## Next Phase Readiness

- All container scripts now support `EXTRA_MOUNTS=/host/path:/container/path` for ad-hoc extra bind mounts
- No user setup required — feature is opt-in via env var

## Self-Check

- [x] `lib.sh` contains `build_extra_mounts` — confirmed
- [x] All 5 container scripts contain `build_extra_mounts` — confirmed via `grep -l`
- [x] All scripts pass `bash -n` syntax check — confirmed
- [x] All 3 verification tests pass — confirmed

## Self-Check: PASSED

---
*Phase: quick*
*Completed: 2026-03-28*
