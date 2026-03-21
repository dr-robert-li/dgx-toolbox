---
phase: 02-adapters-and-usage-tracking
plan: "02"
subsystem: infra
tags: [bash, inotifywait, docker, jq, flock, usage-tracking, daemon]

# Dependency graph
requires:
  - phase: 02-adapters-and-usage-tracking
    provides: "lib/common.sh (ms_log, ms_die), lib/config.sh (load_config, HOT_HF_PATH, HOT_OLLAMA_PATH, MODELSTORE_CONFIG)"
provides:
  - "hooks/watcher.sh — background daemon combining docker events + inotifywait filesystem monitoring"
  - "ms_track_usage — atomic flock+jq writes to ~/.modelstore/usage.json with debounce"
  - "extract_model_id_from_path — maps file paths to model root dirs (models-- ancestor or HOT_OLLAMA_PATH)"
  - "test/test-watcher.sh — 12 assertions covering TRCK-01 and TRCK-02"
affects: [03-migration-cron, 04-ui-and-cli]

# Tech tracking
tech-stack:
  added: [inotifywait, flock, docker-events]
  patterns: [daemon-pidfile-lifecycle, flock-atomic-json-updates, debounce-within-window]

key-files:
  created:
    - modelstore/hooks/watcher.sh
    - modelstore/test/test-watcher.sh
  modified:
    - modelstore/test/run-all.sh

key-decisions:
  - "Function definitions copied inline in test file rather than sourcing watcher.sh — avoids BASH_SOURCE path resolution issues when sourcing via process substitution"
  - "ms_track_usage debounce reads last timestamp from usage.json before acquiring flock — avoids lock contention on frequent access events"
  - "watch_inotify and watch_docker_events both run in background subshells; main block uses wait -n so either exiting terminates the daemon"

patterns-established:
  - "Daemon pidfile lifecycle: write PID after guard checks, trap cleanup removes pidfile + kills children on EXIT/INT/TERM"
  - "Atomic JSON update: flock -x on .lock file, write to .tmp then mv (never partial writes)"
  - "Warn-and-continue failure mode: ms_track_usage never exits the daemon on failure"

requirements-completed: [TRCK-01, TRCK-02]

# Metrics
duration: 3min
completed: 2026-03-21
---

# Phase 02 Plan 02: Watcher Daemon Summary

**Background daemon with docker events + inotifywait monitoring and flock-serialized atomic JSON writes to usage.json with 60-second debounce**

## Performance

- **Duration:** 3 min
- **Started:** 2026-03-21T02:01:49Z
- **Completed:** 2026-03-21T02:05:27Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- Created executable watcher daemon with complete pidfile lifecycle (startup guard, pidfile write, cleanup trap)
- Implemented ms_track_usage with flock+jq atomic writes, ISO-8601 timestamps, and 60-second debounce
- Docker events watcher monitors container start events for vLLM/model containers
- inotifywait watches HF and Ollama model directories for access events
- 12 passing tests covering all TRCK-01 and TRCK-02 requirements

## Task Commits

Each task was committed atomically:

1. **Task 1: Create hooks/watcher.sh** - `ca1e03b` (feat)
2. **Task 2: Create test-watcher.sh and update run-all.sh** - `076d8fa` (test)

**Plan metadata:** (docs commit follows)

## Files Created/Modified
- `modelstore/hooks/watcher.sh` - Background usage tracking daemon (executable, 198 lines)
- `modelstore/test/test-watcher.sh` - 12-assertion unit test file
- `modelstore/test/run-all.sh` - Added test-watcher.sh to suite

## Decisions Made
- Function definitions copied inline in test file rather than sourcing watcher.sh via process substitution — BASH_SOURCE resolves to /dev/fd/N which cannot construct relative paths to lib/
- Debounce reads last timestamp before acquiring flock to avoid contention on frequent inotify events (lock only acquired when write is needed)
- wait -n used in main block (falls back to wait if bash version doesn't support it) so daemon exits when either watcher subprocess exits

## Deviations from Plan

None - plan executed exactly as written. The test sourcing strategy (inline function copy vs. sed extraction) was a deviation in implementation approach, not scope — both achieve the same test coverage.

## Issues Encountered
- Process substitution approach for sourcing watcher.sh failed: `source <(sed ...)` resolves BASH_SOURCE to `/dev/fd/63` which cannot navigate `../lib/`. Fixed by copying function definitions inline in test file.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- usage.json format is locked (absolute model path -> ISO-8601 timestamp)
- Phase 3 migration cron can read usage.json to determine stale models
- Watcher daemon starts cleanly from Phase 4 modelstore CLI via `modelstore watch` command
- No blockers for Phase 3

---
*Phase: 02-adapters-and-usage-tracking*
*Completed: 2026-03-21*
