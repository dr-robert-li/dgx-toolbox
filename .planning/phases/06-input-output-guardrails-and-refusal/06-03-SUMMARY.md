---
phase: 06-input-output-guardrails-and-refusal
plan: "03"
subsystem: guardrails/proxy
tags: [guardrails, proxy, integration, tdd, wiring]
dependency_graph:
  requires: [06-02]
  provides: [guardrail-pipeline-wired, integration-tests-green]
  affects: [harness/proxy/litellm.py, harness/main.py, harness/config/loader.py]
tech_stack:
  added: []
  patterns:
    - getattr(app.state, "guardrail_engine", None) for backward-compatible optional wiring
    - dataclasses.asdict() to serialize RailResult list to JSON-serializable dicts
    - pii_output_proxy_client fixture with per-test MockTransport override
key_files:
  created: []
  modified:
    - harness/proxy/litellm.py
    - harness/config/loader.py
    - harness/config/tenants.yaml
    - harness/main.py
    - harness/tests/test_proxy.py
decisions:
  - "getattr(app.state, 'guardrail_engine', None) guard ensures backward compatibility — existing tests that don't set guardrail_engine on app.state still pass"
  - "TDD GREEN happened immediately — all 8 new tests passed on first run since wiring was correct"
metrics:
  duration_minutes: 4
  tasks_completed: 2
  files_changed: 5
  completed_date: "2026-03-22"
---

# Phase 6 Plan 3: Guardrail Pipeline Wiring Summary

**One-liner:** GuardrailEngine wired inline into proxy route (normalize -> input rails -> proxy -> output rails -> trace) with 8 integration tests proving end-to-end pipeline.

## What Was Built

### Task 1: Extend TenantConfig, wire engine into proxy route and lifespan

- Extended `TenantConfig` in `harness/config/loader.py` with `rail_overrides: Dict[str, Dict[str, object]] = {}` for per-tenant rail threshold/enabled overrides.
- Updated `harness/config/tenants.yaml` to include `rail_overrides: {}` for both dev-team and ci-runner tenants.
- Added `create_guardrail_engine()` call in `harness/main.py` lifespan — guardrail engine initialized at startup with `rails.yaml` config.
- Rewrote `harness/proxy/litellm.py` `chat_completions()` to include the full guardrail pipeline:
  - Unicode normalize via `normalize_messages()` before any rail runs
  - Input rail check via `guardrail_engine.check_input()`
  - Hard block / informative: return 400 with refusal JSON, model never called
  - Soft steer: rebuild messages with system prompt, make second LiteLLM call
  - Bypass tenants: skip entire guardrail pipeline, still get auth and trace
  - Output rail check via `guardrail_engine.check_output()` after LiteLLM response
  - `_write_trace()` extended with `guardrail_decisions` and `is_refusal` parameters

### Task 2: Integration tests for full guardrail pipeline

Added 8 new integration tests to `harness/tests/test_proxy.py`:

| Test | What it verifies |
|------|-----------------|
| `test_hard_block_returns_400` | Injection text blocked at input, 400 returned, LiteLLM not called |
| `test_informative_refusal_content` | PII input returns 400 with message naming `sensitive_data_input` rail |
| `test_bypass_tenant_skips_rails` | bypass=True tenant gets 200 even for injection text |
| `test_clean_request_passthrough` | Clean message gets 200 with LiteLLM response unchanged |
| `test_output_rail_blocks_pii` | LiteLLM PII response redacted to [EMAIL] before delivery |
| `test_trace_guardrail_decisions_populated` | guardrail_decisions is non-null JSON array in trace |
| `test_trace_refusal_event_true` | refusal_event=1 in trace for blocked requests |
| `test_unicode_normalization_before_rails` | Zero-width chars stripped before LiteLLM call |

## Verification Results

- `python -m pytest tests/test_proxy.py -v` → 18 passed (10 existing + 8 new)
- `python -m pytest tests/ -x -q` → 80 passed, 1 skipped (NeMo hardware gate)
- All specific plan verification tests pass: `test_hard_block_returns_400`, `test_bypass_tenant_skips_rails`, `test_trace_refusal_event_true`

## Deviations from Plan

### Auto-fixed Issues

None.

### Design Adaptations

**1. [Rule 2 - Correctness] Used `getattr(app.state, "guardrail_engine", None)` guard**
- **Found during:** Task 1 implementation
- **Issue:** Existing `proxy_client` fixture in tests does NOT set `app.state.guardrail_engine`. Direct attribute access would raise `AttributeError` on old test fixtures.
- **Fix:** Used `getattr(request.app.state, "guardrail_engine", None)` with `if guardrail_engine is not None:` guard. Rails only run when engine is present.
- **Files modified:** harness/proxy/litellm.py

## Commits

| Task | Commit | Description |
|------|--------|-------------|
| Task 1 | 283cd8b | feat(06-03): wire GuardrailEngine into proxy route and lifespan |
| Task 2 | 6957097 | feat(06-03): add guardrail pipeline integration tests |

## Self-Check: PASSED

- All 6 key files found on disk
- Both commits (283cd8b, 6957097) confirmed in git log
- 80 tests pass, 1 skipped (NeMo hardware gate — expected)
