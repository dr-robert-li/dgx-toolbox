---
phase: 11-pipeline-wiring
plan: "01"
subsystem: infra
tags: [bash, autoresearch, huggingface, screen-data, guardrails, data-pipeline]

requires:
  - phase: 06-input-output-guardrails-and-refusal
    provides: harness POST /v1/chat/completions guardrail API on :5000

provides:
  - "Option 6 Local datasets (auto-discovered) in interactive autoresearch launcher"
  - "_discover_local_datasets() function scanning ~/data/ subdirs with file counts"
  - "_select_hf_model() function scanning ~/.cache/huggingface/hub/ with sizes and select menu"
  - "AUTORESEARCH_BASE_MODEL env var support in sync launcher"
  - "local-datasets data source in sync launcher (uses AUTORESEARCH_DATA_PATH as subdir name)"
  - "scripts/screen-data.sh: .txt/.jsonl/.parquet pre-screening through harness guardrails"
  - "scripts/test-data-integration.sh: DATA-01, DATA-02, DATA-03 test suite (9 tests)"

affects:
  - 11-pipeline-wiring (plans 02+)
  - autoresearch launch workflow

tech-stack:
  added: []
  patterns:
    - "mapfile + _discover_local_datasets() for dynamic select menus from filesystem scans"
    - "python3 json.dumps for safe JSON escaping of arbitrary text in bash curl requests"
    - "harness guardrail screening via POST /v1/chat/completions — HTTP 200=clean, 400/403/422=flagged"
    - "HARNESS_API_KEY env var requirement with non-bypass tenant enforcement"

key-files:
  created:
    - scripts/screen-data.sh
    - scripts/test-data-integration.sh
  modified:
    - karpathy-autoresearch/launch-autoresearch.sh
    - karpathy-autoresearch/launch-autoresearch-sync.sh

key-decisions:
  - "mapfile used to capture _discover_local_datasets output into array for nested select menu"
  - "HARNESS_API_KEY validated non-empty before harness health check — clear error points user to dev-team key, not ci-runner (bypass=true)"
  - "_select_hf_model call inserted as section 3b between data source selection and tokenizer validation"
  - "screen-data.sh parquet support gated behind python3 import pandas check with actionable error message"
  - "All records JSON-escaped via python3 -c json.dumps to handle newlines, quotes, unicode safely"

patterns-established:
  - "Pattern: _discover_local_datasets() — find -mindepth 1 -maxdepth 1 -type d -print0 | sort -z with mapfile capture"
  - "Pattern: HF cache model listing — find models--* dirs, convert dashes to slashes, get size with du -sh"
  - "Pattern: harness guardrail screening — POST /v1/chat/completions, interpret HTTP status codes"

requirements-completed: [DATA-01, DATA-02, DATA-03]

duration: 3min
completed: "2026-03-24"
---

# Phase 11 Plan 01: Pipeline Wiring — Data Integration Summary

**Local dataset auto-discovery (option 6), HF cache model selection, and harness-based training data screening added to autoresearch launcher pipeline**

## Performance

- **Duration:** ~3 min
- **Started:** 2026-03-24T01:10:52Z
- **Completed:** 2026-03-24T01:14:00Z
- **Tasks:** 2
- **Files modified:** 4 (2 modified, 2 created)

## Accomplishments

- Option 6 "Local datasets (auto-discovered)" added to interactive launcher — scans ~/data/ subdirs, shows file counts, presents nested select menu
- HF cache model selection step added after data source selection — scans ~/.cache/huggingface/hub/models--* dirs, shows sizes, exports AUTORESEARCH_BASE_MODEL
- Sync launcher updated with local-datasets source and AUTORESEARCH_BASE_MODEL env var support
- screen-data.sh creates two output files: screened records and a removal log with reasons
- All 9 integration tests pass (DATA-01: 3 tests, DATA-02: 2 tests, DATA-03: 4 tests)

## Task Commits

1. **Task 1: Add option 6 and HF model selection to both launchers** - `d646160` (feat)
2. **Task 2: Create screen-data.sh and test suite** - `983d852` (feat)

## Files Created/Modified

- `karpathy-autoresearch/launch-autoresearch.sh` — Added _discover_local_datasets(), _select_hf_model(), option 6 in select menu, updated error message to "1 and 6"
- `karpathy-autoresearch/launch-autoresearch-sync.sh` — Added local-datasets case, AUTORESEARCH_BASE_MODEL support, updated valid values list in error message
- `scripts/screen-data.sh` — New standalone training data pre-screening script through harness guardrails
- `scripts/test-data-integration.sh` — New test suite for DATA-01, DATA-02, DATA-03 (9 tests all passing)

## Decisions Made

- `mapfile` used to capture `_discover_local_datasets` output into array, enabling a nested `select` sub-menu for dataset selection inside the option 6 case handler
- `HARNESS_API_KEY` validation error explicitly warns against ci-runner key (bypass=true skips guardrails) — user must supply dev-team or another non-bypass tenant key
- screen-data.sh uses `python3 -c "import json,sys; print(json.dumps(...))"` for JSON escaping, not bash string manipulation — handles newlines, unicode, and special characters safely
- Parquet support gated behind `python3 -c "import pandas"` check with pip install instructions in the error message

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

For screen-data.sh to work:
- Harness must be running on port 5000 (`docker compose up harness`)
- `HARNESS_API_KEY` must be set to the **dev-team** tenant key (not ci-runner — bypass=true skips guardrails)

## Next Phase Readiness

- DATA-01, DATA-02, DATA-03 requirements complete
- Plan 11-02 (TRSF-01/02/03 + MREG-01/02/03 — eval-checkpoint.sh, autoresearch-deregister.sh) can proceed

---
*Phase: 11-pipeline-wiring*
*Completed: 2026-03-24*
