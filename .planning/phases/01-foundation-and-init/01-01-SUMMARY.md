---
phase: 01-foundation-and-init
plan: 01
subsystem: infra
tags: [bash, jq, json-config, filesystem-validation, cli-router, testing]

# Dependency graph
requires: []
provides:
  - "modelstore/lib/config.sh: config_exists, config_read, load_config, write_config, backup_config_if_exists"
  - "modelstore/lib/common.sh: ms_log, ms_die, check_cold_mounted, check_space, validate_cold_fs"
  - "modelstore.sh: thin CLI router dispatching to cmd/ scripts via exec"
  - "modelstore/ directory skeleton: lib/, cmd/, hooks/, test/fixtures/"
  - "Test infrastructure: smoke.sh, test-config.sh, test-common.sh, run-all.sh"
affects:
  - "02-init-wizard — depends on config.sh and common.sh for all operations"
  - "all subsequent phases — every cmd/ script sources these lib files"

# Tech tracking
tech-stack:
  added:
    - "jq 1.7 (already on host) — JSON config read/write"
    - "findmnt (util-linux, already on host) — filesystem type detection"
    - "mountpoint (util-linux, already on host) — mount verification"
    - "bash inline test assertions (no external framework required)"
  patterns:
    - "BASH_SOURCE[0] for self-relative paths in sourced lib files"
    - "jq -n with --arg/--argjson for safe JSON construction"
    - "findmnt --output FSTYPE for filesystem type detection"
    - "mountpoint -q for mount verification (never test -d)"
    - "set -uo pipefail in test scripts; PASS=$((PASS+1)) not ((PASS++))"
    - "Thin CLI router: router sources libs, then execs cmd/ scripts"
    - "No set -e in lib files; no side effects on source"

key-files:
  created:
    - "modelstore/lib/common.sh — Logging, mount check, space check, filesystem validation"
    - "modelstore/lib/config.sh — JSON config read/write helpers via jq"
    - "modelstore.sh — CLI entry point thin router"
    - "modelstore/test/smoke.sh — Function existence sanity checks"
    - "modelstore/test/test-config.sh — Config round-trip unit tests (14 assertions)"
    - "modelstore/test/test-common.sh — Common function unit tests (11 assertions)"
    - "modelstore/test/run-all.sh — Test suite runner"
  modified: []

key-decisions:
  - "Use PASS=$((PASS+1)) not ((PASS++)) in test scripts with set -e: arithmetic expansion returns exit code 1 when result is 0"
  - "Inline bash assertion pattern (no bats dependency): simpler setup, runs anywhere bash is available"
  - "exec cmd/*.sh in router: preserves process replace semantics, keeps router side-effect-free"
  - "No set -e in lib files: callers control error behavior; lib files must be sourceable without side effects"

patterns-established:
  - "Pattern: BASH_SOURCE[0] in sourced libs for self-relative paths"
  - "Pattern: validate_cold_fs returns 1 on rejection (not exit 1) so callers can handle gracefully"
  - "Pattern: test function mocking via bash function override in test scripts"
  - "Pattern: subshell pattern for testing functions that call exit"

requirements-completed: [INIT-05, INIT-06]

# Metrics
duration: 7min
completed: 2026-03-21
---

# Phase 1 Plan 01: Create project scaffold, lib/common.sh, and lib/config.sh

**JSON config layer (jq), shared bash safety functions (mountpoint/findmnt), CLI router, and 38-test bash suite establishing the foundation all subsequent modelstore scripts depend on**

## Performance

- **Duration:** 7 min
- **Started:** 2026-03-20T23:55:23Z
- **Completed:** 2026-03-21T00:02:42Z
- **Tasks:** 2
- **Files modified:** 10 (7 created + 3 empty dir placeholders)

## Accomplishments
- modelstore/ directory skeleton (lib/, cmd/, hooks/, test/fixtures/) with .gitkeep files
- config.sh with 5 functions: config_exists, config_read, load_config, write_config, backup_config_if_exists — JSON round-trip via jq with chmod 600
- common.sh with 5 functions: ms_log, ms_die, check_cold_mounted, check_space, validate_cold_fs — sources lib.sh via BASH_SOURCE
- modelstore.sh thin router dispatching init/status/migrate/recall/revert to cmd/*.sh via exec
- 38 tests across 3 test files; all pass via run-all.sh in under 5 seconds

## Task Commits

Each task was committed atomically:

1. **Task 1: Create project scaffold, lib/common.sh, and lib/config.sh** - `ded328e` (feat)
2. **Task 2: Create test infrastructure and validate lib functions** - `67d86d0` (feat)

**Plan metadata:** (docs commit follows)

## Files Created/Modified
- `modelstore.sh` — CLI entry point thin router with exec dispatch to cmd/*.sh
- `modelstore/lib/common.sh` — ms_log, ms_die, check_cold_mounted, check_space, validate_cold_fs; sources lib.sh via BASH_SOURCE
- `modelstore/lib/config.sh` — config_exists, config_read, load_config, write_config, backup_config_if_exists; reads/writes ~/.modelstore/config.json via jq
- `modelstore/test/smoke.sh` — 13 function existence assertions
- `modelstore/test/test-config.sh` — 14 config round-trip assertions including load_config, write_config, chmod 600, backup
- `modelstore/test/test-common.sh` — 11 assertions: logging, filesystem rejection (ext4/xfs/btrfs accept; exfat/vfat/ntfs reject), check_space
- `modelstore/test/run-all.sh` — sequential runner exiting non-zero on any failure

## Decisions Made
- **PASS=$((PASS+1)) pattern**: `((PASS++))` evaluates to exit code 1 when PASS=0, triggering `set -e` to exit the test script prematurely. Using `PASS=$((PASS+1))` avoids this. Tests use `set -uo pipefail` (without `-e`) to allow controlled failure handling.
- **validate_cold_fs returns 1 not exit 1**: Returning non-zero rather than calling ms_die allows cmd/init.sh to handle the rejection with a user-friendly message rather than a hard abort.
- **No bats dependency**: Inline bash assertions are simpler to install, run identically everywhere bash is available, and require no package manager.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed ((PASS++)) with set -e causing premature test exit**
- **Found during:** Task 2 (smoke.sh execution)
- **Issue:** `((PASS++))` when PASS=0 evaluates to 0 (falsy), causing `set -e` to exit the test script immediately after the first passing assertion
- **Fix:** Replaced all `((PASS++))` with `PASS=$((PASS + 1))` and changed `set -euo pipefail` to `set -uo pipefail` in test files. This preserves strict mode for unbound variables while allowing test flow control.
- **Files modified:** modelstore/test/smoke.sh, modelstore/test/test-config.sh, modelstore/test/test-common.sh
- **Verification:** All 38 tests pass via run-all.sh
- **Committed in:** 67d86d0 (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 - bug)
**Impact on plan:** Essential fix for test correctness. No scope creep.

## Issues Encountered
None beyond the ((PASS++)) bug documented above.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Foundation complete: config.sh and common.sh are ready to be sourced by cmd/init.sh in Plan 02
- Tested: 38 assertions cover the full function surface area
- No blockers for Plan 02

---
*Phase: 01-foundation-and-init*
*Completed: 2026-03-21*
