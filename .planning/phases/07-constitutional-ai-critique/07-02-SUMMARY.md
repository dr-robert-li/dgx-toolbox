---
phase: 07-constitutional-ai-critique
plan: "02"
subsystem: critique-engine
tags: [constitutional-ai, critique-loop, guardrails, pii, tracing]
dependency_graph:
  requires: [07-01]
  provides: [CritiqueEngine, critique-revise-loop, cai_critique-trace-field]
  affects: [harness/proxy/litellm.py, harness/main.py, harness/critique/engine.py]
tech_stack:
  added: []
  patterns:
    - Risk-gated critique: only runs when score >= critique_threshold AND not blocked
    - Fail-open judge: timeout and parse failures return None (no service disruption)
    - Category-filtered principles: RAIL_TO_CATEGORIES maps rail to relevant categories
    - Judge model sentinel: "default" resolves to request model at call time
    - PII-redact-before-trace: revision redacted before cai_critique dict returned
key_files:
  created:
    - harness/critique/engine.py
    - harness/tests/test_critique.py
  modified:
    - harness/critique/__init__.py
    - harness/proxy/litellm.py
    - harness/main.py
decisions:
  - CritiqueEngine re-checks revision via guardrail_engine.check_output against critique_threshold (not threshold) — ensures revision doesn't need to be completely safe, just below the critique trigger level
  - _MinimalTenant with pii_strictness="minimal" used for revision re-check to avoid double-redacting PII that was already redacted from the revision text
  - asyncio.wait_for with 60s timeout wraps entire _call_judge call including HTTP round-trip
  - All three _write_trace call sites (soft_steer, hard_block early-return, final) pass cai_critique explicitly for clarity
metrics:
  duration_seconds: 329
  completed_date: "2026-03-22"
  tasks_completed: 2
  tasks_total: 2
  files_created: 2
  files_modified: 3
  tests_added: 9
  tests_total_passing: 109
---

# Phase 7 Plan 02: CritiqueEngine and Proxy Integration Summary

**One-liner:** CritiqueEngine implementing risk-gated single-pass critique-revise loop with judge model resolution, category-filtered principles, PII redaction, and cai_critique trace field population.

## What Was Built

### Task 1: CritiqueEngine (TDD — 9 tests)

`harness/critique/engine.py` — CritiqueEngine class with:

- `run_critique_loop()`: risk-gated entry point. Finds first output rail where `score >= critique_threshold` and output was not blocked. Returns `None` for benign outputs (fail-open for timeouts/parse errors).
- `_build_critique_prompt()`: constructs system + user content with category-filtered principles sorted by priority descending.
- `_call_judge()`: direct LiteLLM POST with `response_format={"type": "json_object"}`, bypasses all guardrails.

Key behaviors verified by tests:
- Benign output (score < critique_threshold) returns None with zero judge calls
- High-risk output triggers critique, outcome="revised" when revision passes
- Failed revision (revision score still >= critique_threshold) sets outcome="fallback_hard_block"
- "default" judge_model resolves to request_model, not the sentinel string
- Explicit judge_model used as-is regardless of request model
- Email in revision replaced with [EMAIL] before returning in cai_critique dict
- self_check_output trigger includes safety+accuracy principles, excludes helpfulness
- asyncio.TimeoutError from judge call returns None (service continues)

### Task 2: Proxy and Lifespan Wiring

`harness/main.py`:
- CritiqueEngine initialized after guardrail_engine in lifespan
- FileNotFoundError/ValueError handled: `app.state.critique_engine = None` if constitution.yaml missing or invalid — CAI optional, service runs without it

`harness/proxy/litellm.py`:
- Step 7b inserted between output rails (step 7) and trace write (step 8)
- Only runs when `not tenant.bypass and not is_refusal`
- `getattr(request.app.state, "critique_engine", None)` guard ensures backward compatibility
- Fallback path: `_build_hard_block_refusal("cai_critique")` replaces response_data
- Revised path: `response_data["choices"][0]["message"]["content"]` replaced with revision text
- `_write_trace` signature updated with `cai_critique=None` parameter
- `cai_critique` field in trace record now populated (was hardcoded `None` as Phase 7 placeholder)

## Deviations from Plan

None — plan executed exactly as written.

## Test Results

```
109 passed in ~12s (full harness test suite)
  - 9 new tests in test_critique.py — all pass
  - 100 existing tests — all pass, no regressions
```

## Self-Check: PASSED

| Item | Status |
|------|--------|
| harness/critique/engine.py | FOUND |
| harness/tests/test_critique.py | FOUND |
| commit 4097bf0 (test 07-02) | FOUND |
| commit 0e6f25d (feat 07-02 engine) | FOUND |
| commit 95c015c (feat 07-02 proxy) | FOUND |
