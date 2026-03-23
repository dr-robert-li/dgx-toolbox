---
phase: 08-eval-harness-and-ci-gate
plan: 01
subsystem: testing
tags: [eval, metrics, f1, sqlite, aiosqlite, httpx, safety-dataset, replay-harness]

# Dependency graph
requires:
  - phase: 07-constitutional-ai-critique
    provides: TraceStore with cai_critique field and query_by_timerange method
  - phase: 05-gateway-and-trace-foundation
    provides: TraceStore, schema.sql, gateway POST /v1/chat/completions endpoint
provides:
  - compute_metrics function (F1/precision/recall/CRR/FRR with per-category breakdown)
  - compute_latency_percentiles function (P50/P95)
  - eval_runs SQLite table with source filter and timestamp ordering
  - write_eval_run and query_eval_runs methods on TraceStore
  - run_replay orchestrator (JSONL -> gateway -> score -> store)
  - safety-core.jsonl starter dataset (40 curated cases, 4 categories)
affects:
  - phase 08-02 (CI gate uses eval_runs and run_replay to compare baselines)
  - phase 09-red-teaming (stable eval infrastructure before red teaming)

# Tech tracking
tech-stack:
  added: [httpx (AsyncClient for replay HTTP calls)]
  patterns: [TDD-RED-GREEN per task, async SQLite extension pattern via aiosqlite, JSONL dataset format]

key-files:
  created:
    - harness/eval/__init__.py
    - harness/eval/metrics.py
    - harness/eval/replay.py
    - harness/eval/datasets/safety-core.jsonl
    - harness/tests/test_eval_replay.py
    - harness/tests/test_eval_store.py
  modified:
    - harness/traces/schema.sql
    - harness/traces/store.py

key-decisions:
  - "eval_runs source CHECK constraint enforces only 'replay' or 'lm-eval' — invalid sources fail at DB level"
  - "compute_metrics treats 'steer' same as 'block' for positive class — steered outputs count as correct refusals"
  - "Division by zero in metrics returns 0.0 — consistent behavior for edge cases (all-allow dataset has no positive class)"
  - "run_replay batch-reads traces by timerange after all cases for guardrail_decisions — avoids per-request DB reads during evaluation"
  - "RTK Bash hook changes CWD to harness/ — tests must be run via subprocess from project root or pytest's conftest rootdir"
  - "Latency p50 uses sorted[len//2], p95 uses sorted[int(len*0.95)] — index-based calculation without statistics module"

patterns-established:
  - "Eval dataset pattern: JSONL with prompt/expected_action/category/description fields"
  - "TraceStore extension pattern: add methods to existing class, schema.sql append-only"
  - "Replay mock pattern: patch httpx.AsyncClient return value, mock_client.__aenter__/__aexit__ as AsyncMock"

requirements-completed: [EVAL-01, EVAL-04]

# Metrics
duration: 6min
completed: 2026-03-23
---

# Phase 8 Plan 1: Eval Harness and Starter Dataset Summary

**JSONL replay harness with F1/CRR/FRR classification metrics, P50/P95 latency percentiles, SQLite eval_runs table, and 40-case safety-core.jsonl dataset across injection/PII/toxicity/benign categories**

## Performance

- **Duration:** ~6 min
- **Started:** 2026-03-23T00:04:32Z
- **Completed:** 2026-03-23T00:10:19Z
- **Tasks:** 2
- **Files modified:** 8

## Accomplishments
- `compute_metrics` produces F1/precision/recall/correct_refusal_rate/false_refusal_rate with per-category breakdown; "steer" treated as positive class
- `compute_latency_percentiles` returns P50/P95 from sorted index calculation; empty list returns 0/0
- `eval_runs` table appended to schema.sql with source CHECK constraint and indexes; TraceStore extended with `write_eval_run` and `query_eval_runs` (source filter + DESC ordering)
- `run_replay` orchestrates: load JSONL -> send via httpx -> measure latency -> score -> batch-read traces -> store eval run
- `safety-core.jsonl` contains 40 curated cases: injection (10), pii (8), toxicity (8), benign (14)

## Task Commits

Each task was committed atomically:

1. **Task 1: RED — Failing tests for metrics and eval_runs** - `096d084` (test)
2. **Task 1: GREEN — Metrics module and eval_runs TraceStore extension** - `b88d9c6` (feat)
3. **Task 2: RED — Failing test for run_replay mock integration** - `c0a6dee` (test)
4. **Task 2: GREEN — Replay harness and starter safety dataset** - `1edc00b` (feat)

_Note: TDD tasks have separate RED (test) and GREEN (implementation) commits_

## Files Created/Modified
- `harness/eval/__init__.py` — empty package marker
- `harness/eval/metrics.py` — compute_metrics and compute_latency_percentiles
- `harness/eval/replay.py` — run_replay async orchestrator
- `harness/eval/datasets/safety-core.jsonl` — 40 curated safety test cases
- `harness/tests/test_eval_replay.py` — 8 tests for metrics + 1 integration test for run_replay
- `harness/tests/test_eval_store.py` — 3 tests for write_eval_run and query_eval_runs
- `harness/traces/schema.sql` — appended eval_runs DDL (existing traces DDL untouched)
- `harness/traces/store.py` — added write_eval_run and query_eval_runs methods

## Decisions Made
- `eval_runs` source CHECK constraint (`'replay'` or `'lm-eval'`) enforces valid sources at DB level
- `steer` treated as positive class in compute_metrics — aligns with gateway behavior where steered outputs are refusal events
- Division by zero returns 0.0 for all metrics — avoids exceptions in edge case datasets with no positive class
- Batch trace reads after all cases rather than per-case — decouples replay latency from SQLite reads
- Latency percentiles use index-based calculation (no statistics module) — simpler, pure stdlib

## Deviations from Plan

None — plan executed exactly as written.

The RTK Bash hook CWD issue (tests must run from project root via subprocess) is a tooling observation, not a deviation from the implementation plan.

## Issues Encountered

**RTK CWD issue with pytest:** The RTK Bash hook changes the working directory to `harness/` when running `python -m pytest harness/tests/...`, which causes pytest to fail to find `harness.eval.metrics`. The fix is to always run pytest via `subprocess.run(..., cwd='/home/robert_li/dgx-toolbox')` or directly from the project root. The tests themselves are correct — this is a Bash hook artifact only affecting the Claude Code session, not CI or normal development workflows.

## Next Phase Readiness
- Eval harness and metrics infrastructure complete — ready for Phase 08-02 (CI gate)
- `run_replay` + `eval_runs` table ready for CI comparison against baseline thresholds
- `safety-core.jsonl` starter dataset ready for both CI gate and future red team expansion

---
*Phase: 08-eval-harness-and-ci-gate*
*Completed: 2026-03-23*
