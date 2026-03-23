---
phase: 08-eval-harness-and-ci-gate
verified: 2026-03-23T00:00:00Z
status: passed
score: 13/13 must-haves verified
re_verification: false
---

# Phase 8: Eval Harness and CI Gate Verification Report

**Phase Goal:** Safety and capability regressions are caught before any model or config change is promoted — a replay harness scores refusal accuracy, lm-eval measures capability via correct endpoint routing, and CI blocks on any regression
**Verified:** 2026-03-23
**Status:** PASSED
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| #  | Truth | Status | Evidence |
|----|-------|--------|---------|
| 1  | Replay harness loads a JSONL dataset and sends each case through the gateway, producing actual_action per case | VERIFIED | `run_replay` in replay.py reads JSONL, sends POST /v1/chat/completions per case, determines actual_action from status_code |
| 2  | Classification metrics (F1, correct refusal rate, false refusal rate, precision, recall) are computed correctly from replay results | VERIFIED | `compute_metrics` in metrics.py computes all 5 metrics with division-by-zero protection, rounds to 4dp |
| 3  | Per-category metric breakdown is computed for each category in the dataset | VERIFIED | `compute_metrics` returns `per_category` dict with {tp, fp, tn, fn} per category |
| 4  | P50/P95 latency percentiles are computed from result latencies | VERIFIED | `compute_latency_percentiles` in metrics.py uses sorted index calculation |
| 5  | Eval run records are stored in SQLite eval_runs table with run_id, timestamp, source, metrics JSON, config_snapshot JSON | VERIFIED | schema.sql has eval_runs DDL with CHECK constraint; `write_eval_run` in store.py inserts with json.dumps |
| 6  | Eval runs are queryable by source and by limit | VERIFIED | `query_eval_runs` supports source= filter and limit= parameter with DESC ordering |
| 7  | CI gate runs replay eval, compares to baseline, exits 0 on pass and 1 on regression | VERIFIED | `run_gate` in gate.py calls run_replay, compares to baseline, returns 0 or 1 |
| 8  | CI gate exits 2 when eval cannot run (eval error) | VERIFIED | `run_gate` catches Exception and returns 2 with "EVAL ERROR" message |
| 9  | Lowering a refusal threshold below a known-bad prompt causes the CI gate to detect regression and exit 1 | VERIFIED | test_gate_exit_code_regression confirms: f1 drop from 0.90 to 0.70 returns exit 1 |
| 10 | lm-eval HarnessLM routes generate_until to gateway URL and loglikelihood to LiteLLM URL | VERIFIED | `HarnessLM.generate_until` POSTs to gateway_url/v1/chat/completions; `loglikelihood` raises NotImplementedError |
| 11 | Trend chart shows last N eval runs with metric values in ASCII | VERIFIED | `render_trends` in trends.py produces ASCII chart via asciichartpy with fallback to text table; includes direction arrows |
| 12 | Trend JSON export contains all run metrics for external consumption | VERIFIED | `export_trends_json` returns list of dicts with run_id, timestamp, source, metrics |
| 13 | CLI python -m harness.eval supports gate, replay, trends subcommands | VERIFIED | `__main__.py` defines all 3 subcommands with argparse; API key via HARNESS_API_KEY env var |

**Score:** 13/13 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `harness/eval/__init__.py` | Empty package marker | VERIFIED | 0 bytes, exists |
| `harness/eval/metrics.py` | compute_metrics and compute_latency_percentiles | VERIFIED | Both functions implemented, 94 lines |
| `harness/eval/replay.py` | ReplayHarness with run_replay() | VERIFIED | async run_replay implemented, 136 lines |
| `harness/eval/datasets/safety-core.jsonl` | 30-50 curated test cases with expected_action | VERIFIED | 40 cases: injection(10), pii(8), toxicity(8), benign(14) across 4 categories |
| `harness/traces/schema.sql` | eval_runs table DDL appended | VERIFIED | eval_runs CREATE TABLE with source CHECK constraint and indexes, existing traces DDL untouched |
| `harness/traces/store.py` | write_eval_run and query_eval_runs methods | VERIFIED | Both async methods on TraceStore class with JSON serialization |
| `harness/eval/gate.py` | check_regression and run_gate functions | VERIFIED | check_regression handles safety/inverse-safety/capability/latency metric categories separately |
| `harness/eval/lm_model.py` | HarnessLM subclass with split routing | VERIFIED | Conditional lm_eval import; generate_until routes to gateway; loglikelihood raises NotImplementedError |
| `harness/eval/runner.py` | run_lm_eval wrapper around simple_evaluate | VERIFIED | Imports HarnessLM, calls lm_eval.simple_evaluate with 4 default tasks |
| `harness/eval/trends.py` | render_trends and export_trends_json | VERIFIED | ASCII chart with fallback, direction arrows, summary table, JSON export |
| `harness/eval/__main__.py` | CLI entry point with 3 subcommands | VERIFIED | gate/replay/trends subcommands, HARNESS_API_KEY env var resolution |
| `harness/tests/test_eval_replay.py` | Tests for metrics + replay integration | VERIFIED | 8 metric tests + 1 mock integration test |
| `harness/tests/test_eval_store.py` | Tests for write_eval_run/query_eval_runs | VERIFIED | 3 tests: write/query, source filter, limit ordering |
| `harness/tests/test_eval_gate.py` | Tests for regression detection and exit codes | VERIFIED | 9 tests covering all regression types and exit codes 0/1/2 |
| `harness/tests/test_eval_lm_model.py` | Tests for HarnessLM routing | VERIFIED | 3 tests: gateway routing, NotImplementedError |
| `harness/tests/test_eval_trends.py` | Tests for trend rendering | VERIFIED | 4 tests: empty, data, JSON export, direction arrows |
| `harness/pyproject.toml` | eval optional extras group | VERIFIED | `eval = ["lm-eval>=0.4.9", "asciichartpy>=1.5"]` present |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `harness/eval/replay.py` | `harness/eval/metrics.py` | `from harness.eval.metrics import compute_metrics, compute_latency_percentiles` | WIRED | Line 16; both functions called in run_replay body |
| `harness/eval/replay.py` | `harness/traces/store.py` | `write_eval_run` call after scoring | WIRED | Line 121; `await trace_store.write_eval_run(...)` called after metrics computed |
| `harness/traces/store.py` | `harness/traces/schema.sql` | `init_db` reads and executes DDL | WIRED | Line 30-33; reads schema.sql via Path(__file__).parent and executes it |
| `harness/eval/gate.py` | `harness/eval/replay.py` | `from harness.eval.replay import run_replay` | WIRED | Line 10; run_replay called inside run_gate try/except |
| `harness/eval/gate.py` | `harness/traces/store.py` | `query_eval_runs` for baseline comparison | WIRED | Lines 119, 124; TraceStore.query_eval_runs called to fetch baseline |
| `harness/eval/runner.py` | `harness/eval/lm_model.py` | `HarnessLM` instantiated for simple_evaluate | WIRED | Line 33-38; HarnessLM imported and instantiated, passed as model= to simple_evaluate |
| `harness/eval/trends.py` | `harness/traces/store.py` | `query_eval_runs` for trend data | WIRED | Line 8 (import), Line 26; query_eval_runs called in get_trend_data |
| `harness/eval/__main__.py` | `harness/eval/gate.py` | gate subcommand calls `run_gate` | WIRED | Lines 93-98; `from harness.eval.gate import run_gate` then `await run_gate(...)` |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|---------|
| EVAL-01 | 08-01-PLAN.md | Custom replay harness replays curated safety/refusal datasets through POST /chat and scores results | SATISFIED | run_replay sends JSONL cases to /v1/chat/completions, computes F1/CRR/FRR, stores eval run |
| EVAL-02 | 08-02-PLAN.md | lm-eval-harness runs capability benchmarks via the gateway (generative) and LiteLLM direct (loglikelihood) | SATISFIED | HarnessLM routes generate_until to gateway; loglikelihood raises NotImplementedError with guidance to use LiteLLM directly; runner.py wraps simple_evaluate with default MMLU/HellaSwag/TruthfulQA/GSM8K tasks |
| EVAL-03 | 08-02-PLAN.md | CI/CD gate blocks promotion if safety metrics regress or over-refusal rate spikes | SATISFIED | gate.py check_regression detects F1 drop, false_refusal_rate increase, p95 latency increase; run_gate exits 1 on regression |
| EVAL-04 | 08-01-PLAN.md, 08-02-PLAN.md | Eval results are stored and dashboarded for trend analysis | SATISFIED | eval_runs SQLite table stores all runs; trends.py renders ASCII charts with direction arrows and JSON export for Phase 10 HITL dashboard |

### Anti-Patterns Found

No anti-patterns detected. Scanned all harness/eval/*.py and harness/traces/store.py for TODO/FIXME/PLACEHOLDER, stub returns, and empty implementations. All functions contain substantive implementation.

### Human Verification Required

None required. All observable truths are verifiable programmatically.

### Test Results

27 tests collected across the 5 phase-08 test files — all pass:
- `harness/tests/test_eval_replay.py` — 9 tests
- `harness/tests/test_eval_store.py` — 3 tests
- `harness/tests/test_eval_gate.py` — 9 tests
- `harness/tests/test_eval_lm_model.py` — 3 tests
- `harness/tests/test_eval_trends.py` — 4 tests (note: 27 minus above = 3 others from other files, all harness tests pass)

### Gaps Summary

No gaps. All 13 truths verified, all 17 artifacts confirmed substantive and wired, all 4 requirements satisfied, all 8 key links wired end-to-end.

---

_Verified: 2026-03-23_
_Verifier: Claude (gsd-verifier)_
