---
phase: 11-pipeline-wiring
plan: 02
subsystem: infra
tags: [vllm, litellm, docker, bash, pyyaml, safety-eval, checkpoint, model-registration]

# Dependency graph
requires:
  - phase: 08-eval-harness-and-ci-gate
    provides: python -m harness.eval replay CLI with F1/precision/recall output and safety-core.jsonl dataset
  - phase: 05-gateway-and-trace-foundation
    provides: harness gateway infrastructure (port 5000, LiteLLM proxy on 4000, vLLM on 8020)

provides:
  - scripts/eval-checkpoint.sh — post-training safety eval via temp vLLM container + auto-registration
  - scripts/_litellm_register.py — LiteLLM config add/remove/list with pyyaml backup
  - scripts/autoresearch-deregister.sh — single-command model deregistration from LiteLLM config
  - scripts/test-eval-register.sh — 17-test suite covering TRSF-01/02/03 and MREG-01/02/03

affects:
  - karpathy-autoresearch
  - inference (LiteLLM config management)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - trap EXIT pattern for temp container cleanup guarantees
    - string-append to YAML (comment-safe) for registration; pyyaml parse-modify-dump for deregistration
    - set +e/-e guards around subprocess calls when exit code capture is needed with set -euo pipefail
    - direct-to-vLLM eval gateway (bypasses harness) to measure raw model safety, not harness+model stack

key-files:
  created:
    - scripts/eval-checkpoint.sh
    - scripts/_litellm_register.py
    - scripts/autoresearch-deregister.sh
    - scripts/test-eval-register.sh
  modified: []

key-decisions:
  - "eval-checkpoint.sh points --gateway directly at temp vLLM on :8021 (not harness :5000) — measures raw model safety from training, not harness+model safety stack"
  - "String-append (not pyyaml round-trip) for LiteLLM config registration to preserve existing comments; pyyaml round-trip for deregistration with backup"
  - "docker restart litellm reminder-only (not auto-restart) — auto-restart can lose port bindings in some Docker configs"
  - "STOPPED_PROD_VLLM flag in cleanup trap enables restart-on-exit only when --stop-vllm was used"
  - "set +e/-e guards around subprocess exit code capture inside set -euo pipefail test scripts"

patterns-established:
  - "Pattern 1: Temp container cleanup via trap EXIT — all resources released even on script failure"
  - "Pattern 2: Comment-safe YAML append — grep for duplicates before string-appending YAML block"
  - "Pattern 3: HF checkpoint validation — config.json presence required before vLLM launch"

requirements-completed: [TRSF-01, TRSF-02, TRSF-03, MREG-01, MREG-02, MREG-03]

# Metrics
duration: 4min
completed: 2026-03-24
---

# Phase 11 Plan 02: Pipeline Wiring — Safety Eval and Model Registration Summary

**Post-training safety eval script that starts a temp vLLM container on :8021, runs replay eval against checkpoints, writes safety-eval.json, and auto-registers passing models in LiteLLM config via comment-safe string-append.**

## Performance

- **Duration:** ~4 min
- **Started:** 2026-03-24T01:10:55Z
- **Completed:** 2026-03-24T01:15:07Z
- **Tasks:** 2
- **Files modified:** 4 created

## Accomplishments

- eval-checkpoint.sh validates HF checkpoint format (config.json), runs temp vLLM with trap EXIT cleanup, writes safety-eval.json with F1/precision/recall/pass/timestamp, registers passing models in LiteLLM config (string-append, comment-safe), non-destructive exit 0 on FAILED eval
- _litellm_register.py provides programmatic add/remove/list for LiteLLM config.yaml with pyyaml and timestamped backup before destructive modification
- autoresearch-deregister.sh validates model exists in config before delegating to Python helper for backup-safe removal
- test-eval-register.sh: 17/17 tests pass covering all 6 plan requirements (TRSF-01/02/03, MREG-01/02/03)

## Task Commits

Each task was committed atomically:

1. **Task 1: Create eval-checkpoint.sh and _litellm_register.py** - `4e107ff` (feat)
2. **Task 2: Create autoresearch-deregister.sh and test suite** - `49fcc78` (feat)

**Plan metadata:** TBD (docs: complete plan)

## Files Created/Modified

- `scripts/eval-checkpoint.sh` — post-training safety eval: validates checkpoint, starts temp vLLM, runs replay eval, writes safety-eval.json, auto-registers passing models
- `scripts/_litellm_register.py` — LiteLLM config.yaml management: add/remove/list with pyyaml backup
- `scripts/autoresearch-deregister.sh` — single-command deregistration: validates model exists, calls Python helper
- `scripts/test-eval-register.sh` — 17-test suite for TRSF-01/02/03 and MREG-01/02/03

## Decisions Made

- Direct vLLM eval (--gateway :8021, not harness :5000): measures raw model safety from training, not harness+model stack — more informative for post-training eval intent
- String-append for registration preserves comments in ~/.litellm/config.yaml; pyyaml for deregistration with timestamped backup and warning about comment loss
- docker restart litellm reminder printed, not auto-restart — avoids port binding loss on some Docker versions
- autoresearch/experiment-name model naming pattern from checkpoint dir basename

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Test exit code capture pattern with set -euo pipefail**
- **Found during:** Task 2 (test suite execution)
- **Issue:** `output=$(cmd) || true` + `exit_code=$?` always captures 0 because `|| true` is the last command evaluated
- **Fix:** Used `set +e` / `set -e` guards around subprocess calls, captured exit code in separate variable before restoring strict mode
- **Files modified:** scripts/test-eval-register.sh
- **Verification:** 17/17 tests pass including tests that assert non-zero exit codes
- **Committed in:** 49fcc78 (Task 2 commit)

**2. [Rule 1 - Bug] TRSF-03 grep pattern too strict**
- **Found during:** Task 2 (test suite execution)
- **Issue:** Grep regex `'">\s*"\$\{CHECKPOINT_DIR\}/safety-eval.json"'` didn't match actual `echo "$EVAL_JSON" > "${CHECKPOINT_DIR}/safety-eval.json"` line
- **Fix:** Updated regex to `'>\s+.*CHECKPOINT_DIR.*safety-eval\.json'` matching the actual redirect pattern
- **Files modified:** scripts/test-eval-register.sh
- **Verification:** TRSF-03 test now passes
- **Committed in:** 49fcc78 (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (2 bugs in test patterns)
**Impact on plan:** Both auto-fixes required for correct test assertions. No scope creep. Production scripts unchanged.

## Issues Encountered

None — production scripts (eval-checkpoint.sh, _litellm_register.py, autoresearch-deregister.sh) worked exactly as designed on first run.

## User Setup Required

None - no external service configuration required. The scripts operate against already-running infrastructure (vLLM, LiteLLM, harness).

## Next Phase Readiness

- Plan 11-02 complete: safety eval + model registration scripts ready
- eval-checkpoint.sh requires a user-supplied checkpoint path (HF-format, with config.json)
- After passing eval, user must run `docker restart litellm` to serve the new model
- autoresearch-deregister.sh available for cleanup when model no longer needed
- Plan 11-03 (if any) can proceed — all TRSF and MREG requirements met

## Self-Check: PASSED

- scripts/eval-checkpoint.sh: FOUND
- scripts/_litellm_register.py: FOUND
- scripts/autoresearch-deregister.sh: FOUND
- scripts/test-eval-register.sh: FOUND
- .planning/phases/11-pipeline-wiring/11-02-SUMMARY.md: FOUND
- Commit 4e107ff (Task 1): FOUND
- Commit 49fcc78 (Task 2): FOUND

---
*Phase: 11-pipeline-wiring*
*Completed: 2026-03-24*
