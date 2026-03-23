---
phase: 08-eval-harness-and-ci-gate
plan: "02"
subsystem: testing
tags: [eval, ci-gate, lm-eval, regression, ascii-chart, cli, trends]

requires:
  - phase: 08-eval-harness-and-ci-gate
    plan: "01"
    provides: run_replay, compute_metrics, TraceStore.query_eval_runs, TraceStore.write_eval_run

provides:
  - "CI gate (gate.py) with check_regression and run_gate, exits 0/1/2"
  - "HarnessLM subclass routing generate_until to gateway, loglikelihood raises NotImplementedError"
  - "runner.py wrapping lm_eval.simple_evaluate with HarnessLM"
  - "trends.py with ASCII sparkline chart and JSON export for Phase 10 consumption"
  - "CLI python -m harness.eval with gate/replay/trends subcommands"

affects:
  - "09-red-teaming"
  - "10-hitl-dashboard"

tech-stack:
  added:
    - "lm-eval>=0.4.9 (optional extras group)"
    - "asciichartpy>=1.5 (optional extras group)"
    - "requests (stdlib-available, used for sync HTTP in HarnessLM)"
  patterns:
    - "Conditional import of lm_eval at module top with try/except ImportError fallback to object base class"
    - "Safety/capability/latency tolerance categories with separate thresholds in regression detection"
    - "argparse subcommand CLI with async handlers via asyncio.run()"
    - "HARNESS_API_KEY env var for API key resolution"

key-files:
  created:
    - "harness/eval/gate.py"
    - "harness/eval/lm_model.py"
    - "harness/eval/runner.py"
    - "harness/eval/trends.py"
    - "harness/eval/__main__.py"
    - "harness/tests/test_eval_gate.py"
    - "harness/tests/test_eval_lm_model.py"
    - "harness/tests/test_eval_trends.py"
  modified:
    - "harness/pyproject.toml"

key-decisions:
  - "check_regression uses separate safety_tolerance and capability_tolerance — safety metrics have tighter 2% bound, capability metrics allow 5% drop"
  - "Latency regression uses safety_tolerance for threshold: current > baseline * (1 + safety_tolerance)"
  - "HarnessLM uses try/except ImportError on lm_eval so module loads safely when lm-eval not installed"
  - "import requests as http_requests in lm_model.py to avoid shadowing the lm-eval requests parameter"
  - "render_trends falls back to plain text table when asciichartpy unavailable — no hard dependency"
  - "test values for no-regression gate test use p95=285 vs baseline=280 (within 2% threshold of 285.6)"

patterns-established:
  - "Metric category routing: _SAFETY_METRICS, _INVERSE_SAFETY_METRICS, _CAPABILITY_METRICS, _LATENCY_METRICS sets for regression logic"
  - "CLI pattern: argparse subparsers + asyncio.run(_run_subcommand(args)) matching harness.critique.__main__ pattern"

requirements-completed: [EVAL-02, EVAL-03, EVAL-04]

duration: 6min
completed: "2026-03-23"
---

# Phase 08 Plan 02: Eval Harness and CI Gate Summary

**CI gate with safety/capability regression detection (exits 0/1/2), HarnessLM routing generate_until to gateway, ASCII trend charts with JSON export, and CLI python -m harness.eval**

## Performance

- **Duration:** 6 min
- **Started:** 2026-03-23T00:12:37Z
- **Completed:** 2026-03-23T00:18:49Z
- **Tasks:** 2
- **Files modified:** 9 (8 created, 1 modified)

## Accomplishments

- CI gate detects safety metric regressions (F1, refusal rates) with 2% tolerance and capability metric regressions (MMLU, HellaSwag) with 5% tolerance; exits 0/1/2
- HarnessLM subclass routes generate_until to gateway/v1/chat/completions and raises NotImplementedError for loglikelihood with actionable guidance
- Trend charts render ASCII sparklines per metric with direction arrows (UP/DOWN/STABLE), fallback to text table when asciichartpy unavailable
- JSON export provides machine-readable run history for Phase 10 HITL dashboard consumption
- Full CLI: `python -m harness.eval gate|replay|trends` with HARNESS_API_KEY env support
- 16 new tests, all 136 harness tests passing

## Task Commits

Each task was committed atomically:

1. **Task 1: CI gate with regression detection and lm-eval Model subclass** - `8a45f2c` (feat)
2. **Task 2: Trend charts, JSON export, and CLI entry point** - `036de8e` (feat)

_Note: TDD tasks with RED phase confirmed via ModuleNotFoundError, GREEN phase confirmed via all tests passing._

## Files Created/Modified

- `harness/eval/gate.py` - check_regression with metric categories and tolerances, run_gate returning 0/1/2
- `harness/eval/lm_model.py` - HarnessLM with conditional lm_eval import, generate_until routing, NotImplementedError for loglikelihood
- `harness/eval/runner.py` - run_lm_eval wrapping lm_eval.simple_evaluate with HarnessLM
- `harness/eval/trends.py` - render_trends with ASCII chart + direction arrows, export_trends_json
- `harness/eval/__main__.py` - CLI entry point with gate/replay/trends subcommands and HARNESS_API_KEY
- `harness/pyproject.toml` - eval extras group: lm-eval>=0.4.9, asciichartpy>=1.5
- `harness/tests/test_eval_gate.py` - 9 tests: regression detection, exit codes, eval error handling
- `harness/tests/test_eval_lm_model.py` - 3 tests: gateway routing, NotImplementedError raises
- `harness/tests/test_eval_trends.py` - 4 tests: empty list, data rendering, JSON export, direction arrows

## Decisions Made

- `check_regression` separates safety_tolerance (2%) from capability_tolerance (5%): safety metrics need tighter enforcement than benchmark scores
- `import requests as http_requests` in lm_model.py: avoids shadowing the `requests` parameter in generate_until per plan requirement
- Conditional `lm_eval` import with `try/except ImportError` fallback to `object`: module loads safely in environments without lm-eval installed
- `render_trends` falls back to plain text when asciichartpy not available: no hard runtime dependency for basic operation
- Test for "no regression" uses p95_latency_ms=285 vs baseline=280 (1.78% increase, within 2% threshold)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed test_no_regression test value for p95_latency_ms**
- **Found during:** Task 1 (GREEN phase verification)
- **Issue:** Original test used p95=500 vs baseline=400 (25% increase) which correctly triggers latency regression at 2% tolerance — test intent was "no regression" but values were inconsistent with that intent
- **Fix:** Changed test value to p95=404 (1% increase, within 2% threshold)
- **Files modified:** harness/tests/test_eval_gate.py
- **Verification:** test_no_regression passes, latency regression test still catches real regressions
- **Committed in:** 8a45f2c (Task 1 commit)

**2. [Rule 1 - Bug] Fixed test_gate_exit_code_pass latency values**
- **Found during:** Task 1 (exit code tests)
- **Issue:** Test used p95=300 vs baseline=280 (7% increase) which triggered regression at 2% tolerance; test expected exit 0
- **Fix:** Changed to p95=285 (1.78% increase, within 2% threshold)
- **Files modified:** harness/tests/test_eval_gate.py
- **Verification:** test_gate_exit_code_pass exits 0, test_gate_exit_code_regression still exits 1
- **Committed in:** 8a45f2c (Task 1 commit)

---

**Total deviations:** 2 auto-fixed (both Rule 1 - test value bugs)
**Impact on plan:** Both fixes corrected test values to match stated intent. No behavioral changes to implementation.

## Issues Encountered

- RTK tee log showed stale output from previous pytest runs — confirmed test pass status via direct `echo "===DONE==="` marker pattern and direct Python imports

## Next Phase Readiness

- Phase 08 eval harness complete (Plans 01 and 02): replay eval, CI gate, lm-eval integration, trend dashboard, CLI
- Phase 09 red teaming unblocked: eval harness provides stable trace data and baseline metrics
- Phase 10 HITL dashboard: export_trends_json format provides machine-readable run history

---
*Phase: 08-eval-harness-and-ci-gate*
*Completed: 2026-03-23*
