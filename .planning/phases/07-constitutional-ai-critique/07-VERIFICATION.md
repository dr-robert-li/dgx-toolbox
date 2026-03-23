---
phase: 07-constitutional-ai-critique
verified: 2026-03-22T13:15:00Z
status: passed
score: 16/16 must-haves verified
re_verification: true
  previous_status: gaps_found
  previous_score: 15/16
  gaps_closed:
    - "POST /admin/suggest-tuning triggers analysis and returns the report"
  gaps_remaining: []
  regressions: []
---

# Phase 7: Constitutional AI Critique Verification Report

**Phase Goal:** Outputs that pass guardrails but score as high-risk trigger a two-pass critique-and-revise loop against a user-editable constitution — low-risk outputs are never touched — and the judge model can analyze trace history to produce actionable tuning suggestions

**Verified:** 2026-03-22T13:15:00Z
**Status:** passed
**Re-verification:** Yes — after gap closure (commit ff09ef5)

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Valid constitution.yaml loads at startup and produces ConstitutionConfig with typed Principle objects | VERIFIED | `constitution.py`: ConstitutionFile.model_validate + load_constitution(); constitution.yaml has 12 principles in 4 categories |
| 2 | Malformed constitution.yaml raises ValueError at startup before service accepts traffic | VERIFIED | `load_constitution()` raises ValueError on empty YAML and on schema validation failure; main.py catches this gracefully |
| 3 | Disabled principles are filterable from the principle list | VERIFIED | Principle.enabled field; CritiqueEngine filters `p.enabled` in principle selection; test_disabled_principle_excluded |
| 4 | critique_threshold on output rail defines risk band between critique_threshold and threshold | VERIFIED | RailConfig.critique_threshold: Optional[float] = None; rails.yaml has 0.5/0.15 on output rails only |
| 5 | critique_threshold >= threshold rejected at startup | VERIFIED | model_validator raises ValueError; test_critique_threshold_invalid and equal_invalid both pass |
| 6 | Input rails have no critique_threshold | VERIFIED | rails.yaml: 4 input rails have no critique_threshold field; validated by test_input_rails_no_critique_threshold |
| 7 | High-risk output (score >= critique_threshold but < threshold) triggers critique-revise cycle | VERIFIED | CritiqueEngine.run_critique_loop(); proxy step 7b wired between output rails and trace write |
| 8 | Revised output replaces original response delivered to client | VERIFIED | litellm.py line 204: `response_data["choices"][0]["message"]["content"] = critique_result["judge_response"]["revision"]` |
| 9 | Revision still scoring high-risk falls back to hard block | VERIFIED | revision_score >= revision_critique_threshold sets outcome="fallback_hard_block"; proxy calls `_build_hard_block_refusal("cai_critique")` |
| 10 | Benign output (score < critique_threshold) results in exactly 1 model call | VERIFIED | run_critique_loop returns None when no rail exceeds critique_threshold; test_benign_no_critique passes |
| 11 | Judge model calls bypass guardrails (direct LiteLLM http_client) | VERIFIED | _call_judge posts directly to http_client.post("/v1/chat/completions") without going through guardrail checks |
| 12 | cai_critique trace field contains structured JSON with triggered_by, judge_model, judge_response, outcome | VERIFIED | Return dict in run_critique_loop has all 4 keys; _write_trace receives `cai_critique=cai_critique_data` |
| 13 | Judge model identifier in trace is actual model name, not "default" sentinel | VERIFIED | `if self._constitution.judge_model == "default": resolved_judge_model = request_model`; test_judge_model_id_in_trace passes |
| 14 | PII is redacted from revision text before storing in cai_critique trace field | VERIFIED | `redacted_revision = redact(judge_response["revision"], pii_strictness)` before dict assembly; test_pii_redacted_in_critique passes |
| 15 | analyze_traces() queries SQLite for traces with non-null cai_critique and returns ranked tuning suggestions | VERIFIED | analyzer.py: query_by_timerange + filter cai_critique != None + judge call + ranked report; 6 tests pass |
| 16 | POST /admin/suggest-tuning triggers analysis and returns the report | VERIFIED | engine.py lines 57-60: `@property constitution` added in commit ff09ef5; `critique_engine.constitution` in admin.py line 35 now resolves correctly; runtime test confirms no AttributeError |

**Score:** 16/16 truths verified

---

## Required Artifacts

| Artifact | Provides | Status | Details |
|----------|----------|--------|---------|
| `harness/critique/constitution.py` | ConstitutionConfig, Principle, ConstitutionFile, load_constitution() | VERIFIED | All 4 classes/functions present; substantive implementation |
| `harness/critique/__init__.py` | Package init exporting public API | VERIFIED | Exports ConstitutionConfig, Principle, ConstitutionFile, load_constitution, CritiqueEngine, analyze_traces |
| `harness/config/constitution.yaml` | Default 12 principles in 4 categories | VERIFIED | Contains all required principle IDs (P-SAFETY-01 through P-HELPFULNESS-02), judge_model: default |
| `harness/config/rail_loader.py` | RailConfig with critique_threshold and cross-field validator | VERIFIED | critique_threshold: Optional[float] = None + @model_validator(mode='after') |
| `harness/config/rails/rails.yaml` | critique_threshold on output rails | VERIFIED | self_check_output: 0.5, jailbreak_output: 0.5, sensitive_data_output: 0.15; input rails have none |
| `harness/critique/engine.py` | CritiqueEngine with run_critique_loop, _call_judge, _build_critique_prompt, @property constitution | VERIFIED | All three methods present; RAIL_TO_CATEGORIES mapping; response_format json_object; PII redaction; @property constitution added at lines 57-60 |
| `harness/proxy/litellm.py` | Critique loop wired between output rails and trace write | VERIFIED | Step 7b at line 182-206; critique_engine.run_critique_loop() called; cai_critique passed to _write_trace |
| `harness/main.py` | CritiqueEngine initialized in lifespan | VERIFIED | Lines 58-69: load_constitution + CritiqueEngine init with try/except; app.state.critique_engine set |
| `harness/critique/analyzer.py` | analyze_traces() with MIN_SAMPLE_SIZE guard, aggregation, judge call, report + yaml_diffs | VERIFIED | All required content present; 6 tests pass |
| `harness/critique/__main__.py` | CLI entry: python -m harness.critique analyze --since 24h | VERIFIED | main(), analyze_parser, --since arg, asyncio.run(_run_analyze) |
| `harness/proxy/admin.py` | POST /admin/suggest-tuning FastAPI endpoint | VERIFIED | Endpoint defined and registered; critique_engine.constitution access now works via @property; admin_router.routes confirmed: ['/admin/suggest-tuning'] |
| `harness/tests/test_constitution.py` | 8 constitution tests | VERIFIED | All 8 test functions present and passing |
| `harness/tests/test_rail_config.py` | critique_threshold validation tests | VERIFIED | 6 new tests including invalid/equal_invalid/rails_yaml/input_rails |
| `harness/tests/test_critique.py` | 9 CritiqueEngine unit tests | VERIFIED | All 9 tests including timeout, PII, fallback, benign bypass |
| `harness/tests/test_analyzer.py` | 6 analyzer tests | VERIFIED | All 6 tests pass |

---

## Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| harness/critique/constitution.py | harness/config/constitution.yaml | yaml.safe_load + ConstitutionFile.model_validate | WIRED | load_constitution() reads YAML and validates via Pydantic |
| harness/config/rail_loader.py | harness/config/rails/rails.yaml | load_rails_config parses critique_threshold | WIRED | critique_threshold: Optional[float] = None in RailConfig |
| harness/proxy/litellm.py | harness/critique/engine.py | getattr(request.app.state, 'critique_engine', None).run_critique_loop | WIRED | Step 7b lines 185-206 |
| harness/critique/engine.py | LiteLLM via http_client | _call_judge posts to /v1/chat/completions | WIRED | http_client.post("/v1/chat/completions", json={..., "response_format": {"type": "json_object"}}) |
| harness/main.py | harness/critique/engine.py | CritiqueEngine instantiation in lifespan | WIRED | app.state.critique_engine = CritiqueEngine(constitution=constitution, ...) |
| harness/proxy/litellm.py | harness/traces/store.py | _write_trace receives cai_critique parameter | WIRED | cai_critique=cai_critique_data at line 220; _write_trace stores it in record dict |
| harness/critique/analyzer.py | harness/traces/store.py | query_by_timerange | WIRED | `rows = await trace_store.query_by_timerange(since=since)` |
| harness/proxy/admin.py | harness/critique/analyzer.py | from harness.critique.analyzer import analyze_traces + critique_engine.constitution | WIRED | Import exists; call exists; critique_engine.constitution resolves via @property (fix: ff09ef5) |
| harness/main.py | harness/proxy/admin.py | app.include_router(admin_router) | WIRED | Line 88 in main.py confirmed |

---

## Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| CSTL-01 | 07-02 | Flagged outputs go through critique→revise pipeline against constitutional principles | SATISFIED | CritiqueEngine.run_critique_loop() in engine.py; proxy step 7b; 9 tests pass |
| CSTL-02 | 07-01 | Constitutional principles are user-editable via YAML config, validated on startup | SATISFIED | constitution.yaml with 12 user-editable principles; load_constitution() raises ValueError on invalid YAML; tested by test_constitution.py |
| CSTL-03 | 07-02 | Judge model is configurable (default same-model, swappable to dedicated judge) | SATISFIED | constitution.judge_model field; "default" sentinel resolves to request_model; test_judge_model_id_in_trace and test_judge_model_configured |
| CSTL-04 | 07-01 | CAI critique is risk-gated — only triggered for outputs classified as high-risk by output rails | SATISFIED | critique_threshold field on RailConfig; only fires when score >= critique_threshold AND result != "block"; test_benign_no_critique |
| CSTL-05 | 07-03 | Judge model provides AI-guided suggestions for guardrail and constitution tuning based on trace history | SATISFIED | analyze_traces() works correctly; CLI works; POST /admin/suggest-tuning endpoint wired and attribute access fixed by commit ff09ef5; 109 tests pass, 0 failures |

---

## Anti-Patterns Found

None. The previous blocker (accessing `critique_engine.constitution` on a class that only had `self._constitution`) has been resolved by adding `@property constitution` to `CritiqueEngine` in commit ff09ef5. No TODO/FIXME/placeholder comments found in implementation files. No empty stub returns found in critical paths.

---

## Human Verification Required

None — all behavioral paths are verifiable from the code.

---

## Re-verification Summary

**Gap closed:** The single blocker from initial verification is resolved.

The gap was: `admin.py` line 35 accessed `critique_engine.constitution` which raised `AttributeError` because `CritiqueEngine.__init__` stored only `self._constitution` (private). Commit `ff09ef5` added a `@property constitution` returning `self._constitution` (engine.py lines 57-60). Runtime verification confirms `engine.constitution` returns a `ConstitutionConfig` instance with no exception. The admin endpoint `/admin/suggest-tuning` is registered in main.py at line 88 and its route is confirmed active.

Full test suite result: **109 passed, 1 skipped, 0 failures** — no regressions introduced by the fix.

All 5 CSTL requirements (CSTL-01 through CSTL-05) are fully satisfied. Phase goal is achieved.

---

_Verified: 2026-03-22T13:15:00Z_
_Verifier: Claude (gsd-verifier)_
