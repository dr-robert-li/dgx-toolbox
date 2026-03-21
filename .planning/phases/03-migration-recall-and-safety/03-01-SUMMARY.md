---
phase: 03-migration-recall-and-safety
plan: 01
subsystem: infra
tags: [bash, rsync, flock, jq, audit-log, cron, ollama, huggingface]

# Dependency graph
requires:
  - phase: 02-adapters-and-usage-tracking
    provides: hf_migrate_model, hf_recall_model with atomic symlink swap; ollama_adapter stubs with SAFE-01/02/06 guards; usage.json flock+jq pattern

provides:
  - audit_log() with annual rotation in lib/audit.sh
  - Fully implemented ollama_migrate_model with blob reference counting
  - Fully implemented ollama_recall_model with symlink detection and blob restoration
  - cmd/migrate.sh migration orchestrator with --dry-run, stale detection, state file, adapter dispatch
  - cron/migrate_cron.sh with flock -n concurrency guard
  - test-migrate.sh covering MIGR-01 through MIGR-07 and SAFE-05
  - test-audit.sh covering MIGR-08

affects: [04-cli-and-status, recall-sh, disk-check-cron]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - audit_log() flock+jq atomic append reuses ms_track_usage pattern from watcher.sh
    - Annual rotation by comparing log year to current year via head -1 | jq
    - Ollama blob reference counting via grep -rl on hot manifests before moving
    - State file atomic write via jq > .tmp && mv (never partially written)
    - 4-hour stale state timeout to prevent indefinite blocking from kill -9 crashes

key-files:
  created:
    - modelstore/lib/audit.sh
    - modelstore/cmd/migrate.sh
    - modelstore/cron/migrate_cron.sh
    - modelstore/test/test-migrate.sh
    - modelstore/test/test-audit.sh
  modified:
    - modelstore/lib/ollama_adapter.sh

key-decisions:
  - "cron_output unbound variable with set -uo pipefail fixed by using tee to temp file instead of command substitution with background process"
  - "Ollama recall derives cold_base dynamically by following a hot blob symlink's readlink target — more robust than passing cold_base as a parameter"
  - "find_stale_hf_models uses USAGE_FILE jq check + directory walk, skipping symlinks in both paths to avoid re-migrating already-migrated models"

patterns-established:
  - "Interrupt-safe multi-step operations: _write_op_state before each phase, _clear_op_state after completion"
  - "Stale state file detection: check started_at age at startup, clear if older than 4 hours"

requirements-completed: [MIGR-01, MIGR-02, MIGR-03, MIGR-04, MIGR-05, MIGR-06, MIGR-07, MIGR-08, SAFE-05]

# Metrics
duration: 6min
completed: 2026-03-21
---

# Phase 3 Plan 01: Migration Pipeline Summary

**Blob reference-counted Ollama migration, JSON audit log with annual rotation, and full cron/migrate.sh orchestrator with --dry-run, flock guard, and interrupt-safe state file**

## Performance

- **Duration:** 6 min
- **Started:** 2026-03-21T12:58:18Z
- **Completed:** 2026-03-21T13:04:33Z
- **Tasks:** 3
- **Files modified:** 6

## Accomplishments
- Created lib/audit.sh providing audit_log() with atomic flock+jq writes and annual log rotation at year boundary
- Filled ollama_migrate_model with full blob reference counting (shared blobs copied but not moved when ref count > 1)
- Created cmd/migrate.sh with --dry-run two-section table output, stale detection from usage.json, interrupt-safe state file (op_state.json), and adapter dispatch for both HF and Ollama
- Created cron/migrate_cron.sh thin wrapper with flock -n non-blocking concurrency guard that exits 0 with message when lock held
- 21 tests pass: 12 in test-migrate.sh (MIGR-01 through MIGR-07, SAFE-05) and 9 in test-audit.sh (MIGR-08)

## Task Commits

Each task was committed atomically:

1. **Task 1: Create lib/audit.sh and fill Ollama adapter migrate/recall bodies** - `8727a80` (feat)
2. **Task 2: Create cmd/migrate.sh and cron/migrate_cron.sh** - `ab95b1d` (feat)
3. **Task 3: Create test-migrate.sh and test-audit.sh** - `ed5ccb7` (test)

## Files Created/Modified
- `modelstore/lib/audit.sh` - audit_log() with flock+jq atomic append, _audit_rotate_if_needed() annual rotation
- `modelstore/lib/ollama_adapter.sh` - Filled ollama_migrate_model and ollama_recall_model with blob ref-counting; added _ollama_manifest_blobs and _ollama_blob_hot_refs helpers
- `modelstore/cmd/migrate.sh` - Migration orchestrator: stale detection, --dry-run table output, op_state.json interrupt safety, hf_migrate_model + ollama_migrate_model dispatch with audit_log
- `modelstore/cron/migrate_cron.sh` - Thin cron wrapper with flock -n guard, sets TRIGGER_SOURCE=cron, delegates to cmd/migrate.sh
- `modelstore/test/test-migrate.sh` - 12 tests covering MIGR-01 through MIGR-07 and SAFE-05
- `modelstore/test/test-audit.sh` - 9 tests covering MIGR-08 (all audit event types, rotation, concurrent safety)

## Decisions Made
- Ollama recall derives cold_base by following a hot blob symlink via readlink — more robust than requiring cold_base as a parameter since the symlink points directly into the cold location
- Used `tee` to a temp file for MIGR-06 flock test because command substitution with background processes and `set -uo pipefail` produces unbound variable errors
- find_stale_hf_models checks `[[ -L "$key" ]]` before the untracked-model loop to avoid incorrectly re-migrating already-migrated models

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed cron flock test unbound variable with set -uo pipefail**
- **Found during:** Task 3 (test-migrate.sh)
- **Issue:** `cron_output=$(...) &` with `set -uo pipefail` causes unbound variable because background subshell doesn't assign to parent variable
- **Fix:** Used `tee "$cron_out_file"` piped output then `cat` after wait — avoids the variable scoping issue
- **Files modified:** modelstore/test/test-migrate.sh
- **Verification:** MIGR-06 test passes
- **Committed in:** ed5ccb7 (Task 3 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 - bug)
**Impact on plan:** Essential fix for test correctness. No scope creep.

## Issues Encountered
None beyond the flock test fix documented above.

## Next Phase Readiness
- Audit logging infrastructure ready for recall.sh and disk_check_cron.sh
- cmd/migrate.sh ready to be wired into modelstore.sh CLI dispatcher (Phase 4)
- Ollama adapter migrate/recall bodies complete — ready for recall.sh to call ollama_recall_model
- Remaining Phase 3 plans: recall.sh, disk_check_cron.sh, watcher recall trigger extension

## Self-Check: PASSED

All files exist. All task commits verified (8727a80, ab95b1d, ed5ccb7). Tests: 21 passed, 0 failed.

---
*Phase: 03-migration-recall-and-safety*
*Completed: 2026-03-21*
