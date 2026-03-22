---
phase: 06-input-output-guardrails-and-refusal
verified: 2026-03-22T08:00:00Z
status: passed
score: 13/13 must-haves verified
re_verification: false
gaps: []
human_verification: []
---

# Phase 6: Input/Output Guardrails and Refusal Verification Report

**Phase Goal:** All requests are screened before the model and all outputs are screened before delivery — with user-configurable per-rail thresholds and three distinct refusal modes — using Unicode-normalized input so guardrail evasion via encoding tricks is impossible

**Verified:** 2026-03-22T08:00:00Z
**Status:** passed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|---------|
| 1 | Unicode text with zero-width characters is stripped before any classifier runs | VERIFIED | `normalizer.py` _ZERO_WIDTH_PATTERN strips 12 chars; `normalize_messages()` called first in proxy; `test_unicode_normalization_before_rails` confirms stripped content reaches LiteLLM |
| 2 | Unicode text with homoglyphs is NFKC-normalized and flagged before any classifier runs | VERIFIED | `normalize()` applies `unicodedata.normalize("NFKC", text)` then `confusables.is_confusable()` flags "homoglyph_detected"; `test_homoglyph_flagged` passes |
| 3 | Each rail in rails.yaml has enabled, threshold, and refusal_mode fields validated at load time | VERIFIED | `RailConfig(BaseModel)` with `Literal["hard_block", "soft_steer", "informative"]` enforces all three fields; `load_rails_config()` raises `ValueError` on invalid config |
| 4 | Invalid rails.yaml causes a Pydantic ValidationError at startup, not silent fallback | VERIFIED | `load_rails_config()` wraps `ValidationError` in `ValueError`; `test_load_rails_config_invalid_mode` confirms invalid mode raises ValueError |
| 5 | A user edits a threshold in rails.yaml and the changed value is loaded on next startup | VERIFIED | `load_rails_config()` reads from file at startup (called in `create_guardrail_engine()`); `test_load_rails_config_valid` confirms 7 rails with correct threshold values loaded from file |
| 6 | Content filter blocks disallowed input topics via NeMo self check input | VERIFIED | `check_input()` runs `_run_nemo_rail("self_check_input", ...)` for all messages; `test_content_filter_blocks` with mock NeMo confirms `blocked=True`, `triggering_rail="self_check_input"` |
| 7 | PII in input is detected and triggers the configured refusal mode | VERIFIED | `_check_pii_input()` uses Presidio redactor; `sensitive_data_input` rail configured as "informative"; `test_pii_input_blocked` and `test_informative_refusal_content` pass |
| 8 | Regex heuristic detects known prompt injection patterns before NeMo LLM-as-judge | VERIFIED | `INJECTION_PATTERNS` (6 compiled regexes) checked in `_check_injection_regex()`; runs before NeMo rails; `test_injection_regex_detected` and `test_injection_regex_variants` pass |
| 9 | Toxic or jailbreak-success output is intercepted before delivery | VERIFIED | `check_output()` runs `self_check_output` and `jailbreak_output` via NeMo; `test_toxic_output_blocked` confirms `replacement_response` populated |
| 10 | PII in output is detected and redacted before delivery | VERIFIED | `_check_pii_output()` uses Presidio; `_build_redacted_response()` replaces content; `test_pii_output_redacted` confirms "[EMAIL]" in replacement; integration test `test_output_rail_blocks_pii` passes |
| 11 | Hard block produces a principled refusal with no model call | VERIFIED | Hard block returns 400 before reaching LiteLLM; `_build_hard_block_refusal()` returns "violates our content policy"; `test_hard_block_returns_400` and `test_hard_block_refusal_content` pass |
| 12 | Soft steer submits rewritten prompt to LiteLLM with reformulation system prompt | VERIFIED | `_build_soft_steer_messages()` prepends `SOFT_STEER_SYSTEM_PROMPT`; proxy makes second LiteLLM call when `refusal_mode == "soft_steer"`; `test_soft_steer_messages` confirms message structure |
| 13 | Informative refusal names the violated policy and suggests adjacent help | VERIFIED | `_build_informative_refusal()` includes rail name + `_RAIL_SUGGESTIONS`; `test_informative_refusal_content` (unit) and `test_informative_refusal_content` (integration) both pass |

**Score:** 13/13 truths verified

---

## Required Artifacts

| Artifact | Expected | Status | Details |
|----------|---------|--------|---------|
| `harness/guards/normalizer.py` | NFKC normalization, zero-width stripping, homoglyph detection | VERIFIED | 88 lines; exports `normalize`, `normalize_messages`; uses `_ZERO_WIDTH_PATTERN`, `confusables.is_confusable()`, `unicodedata.normalize("NFKC")` |
| `harness/guards/types.py` | GuardrailDecision and RailResult dataclasses | VERIFIED | 32 lines; `RailResult` and `GuardrailDecision` with all required fields including `refusal_mode`, `evasion_flags` |
| `harness/config/rail_loader.py` | Pydantic RailConfig model and load_rails_config() | VERIFIED | 56 lines; `RailConfig(BaseModel)` with `Literal["hard_block","soft_steer","informative"]`; `load_rails_config()` raises `ValueError` on parse/validation failure |
| `harness/config/rails/rails.yaml` | Per-rail config with enabled/threshold/refusal_mode | VERIFIED | 30 lines; 7 rails all with `enabled`, `threshold`, `refusal_mode`; `refusal_mode: hard_block` present |
| `harness/config/rails/config.yml` | NeMo Guardrails config for LLMRails.from_path() | VERIFIED | Contains `self check input`, `mask sensitive data on input`; full input/output flow references |
| `harness/config/rails/input_output.co` | Colang 1.0 flow definitions for self-check input/output | VERIFIED | Contains `define flow self check input`, `define flow self check output`, `bot refuse to respond` |
| `harness/guards/engine.py` | GuardrailEngine with check_input/check_output and refusal mode handlers | VERIFIED | 500 lines; exports `GuardrailEngine`, `create_guardrail_engine`; all refusal builders present |
| `harness/guards/__init__.py` | Exports GuardrailEngine and create_guardrail_engine | VERIFIED | Exports both symbols plus nemo_compat probes |
| `harness/proxy/litellm.py` | Proxy route with inline normalize + input rails + output rails | VERIFIED | Contains `normalize_messages`, `guardrail_engine.check_input()`, `guardrail_engine.check_output()`, `input_decision.blocked`, `output_decision.blocked`, soft steer branch, `status_code=400` |
| `harness/config/loader.py` | Extended TenantConfig with rail_overrides field | VERIFIED | `rail_overrides: Dict[str, Dict[str, object]] = {}` added to `TenantConfig` |
| `harness/main.py` | GuardrailEngine initialization in lifespan | VERIFIED | `create_guardrail_engine()` called in `lifespan()`, assigned to `app.state.guardrail_engine` |
| `harness/config/tenants.yaml` | rail_overrides field for both tenants | VERIFIED | Both `dev-team` and `ci-runner` have `rail_overrides: {}` |
| `harness/tests/test_normalizer.py` | Normalizer tests (9 tests) | VERIFIED | 105 lines; covers NFKC, zero-width, homoglyph, normalize_messages, all 12 zero-width chars |
| `harness/tests/test_rail_config.py` | Rail config loading tests (6 tests) | VERIFIED | 106 lines; covers valid load, invalid mode, empty, missing name, defaults, all 3 modes |
| `harness/tests/test_guardrails.py` | GuardrailEngine unit tests (19 tests) | VERIFIED | 284 lines; covers all input/output rails, refusal modes, threshold, run-all-rails |
| `harness/tests/test_proxy.py` | Integration tests for guardrail pipeline (8 new tests) | VERIFIED | 663 lines; 8 Phase 6 integration tests appended without removing Phase 5 tests |
| `harness/pyproject.toml` | Dependencies: confusable-homoglyphs, langchain-openai, nemoguardrails | VERIFIED | All three present with correct version constraints |

---

## Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `harness/config/rail_loader.py` | `harness/config/rails/rails.yaml` | `yaml.safe_load + Pydantic validation` | WIRED | `load_rails_config()` reads the file, passes through `RailsFile.model_validate()` |
| `harness/guards/normalizer.py` | `confusable_homoglyphs` | `confusables.is_confusable()` | WIRED | Line 12: `from confusable_homoglyphs import confusables`; line 48: `confusables.is_confusable(stripped, preferred_aliases=["latin"])` |
| `harness/guards/engine.py` | `harness/config/rail_loader.py` | `load_rails_config()` at init | WIRED | `create_guardrail_engine()` calls `load_rails_config(rails_config_path)` |
| `harness/guards/engine.py` | `harness/guards/types.py` | returns GuardrailDecision from check_input/check_output | WIRED | Line 17: `from harness.guards.types import GuardrailDecision, RailResult`; returned from both methods |
| `harness/guards/engine.py` | `harness/guards/normalizer.py` | calls `normalize()` in check_input | WIRED | Line 16: `from harness.guards.normalizer import normalize_messages`; called at line 115 in `check_input()` |
| `harness/proxy/litellm.py` | `harness/guards/engine.py` | `request.app.state.guardrail_engine.check_input/check_output` | WIRED | Lines 78, 164: `guardrail_engine.check_input()` and `guardrail_engine.check_output()` called via `getattr(request.app.state, "guardrail_engine", None)` |
| `harness/proxy/litellm.py` | `harness/guards/normalizer.py` | `normalize_messages()` before check_input | WIRED | Line 16: `from harness.guards.normalizer import normalize_messages`; called at line 74 before input rails |
| `harness/main.py` | `harness/guards/engine.py` | `create_guardrail_engine()` in lifespan | WIRED | Lines 49-56: imports and calls `create_guardrail_engine()` in `lifespan()` |
| `harness/config/loader.py` | `harness/config/rail_loader.py` | TenantConfig.rail_overrides references RailConfig names | WIRED | `rail_overrides: Dict[str, Dict[str, object]] = {}` added; naming convention matches `RailConfig.name` |

---

## Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|------------|------------|-------------|--------|---------|
| INRL-01 | Plans 01, 03 | Input is normalized (Unicode NFC/NFKC + zero-width stripping) before any classifier runs | SATISFIED | `normalizer.py` NFKC + zero-width stripping; called via `normalize_messages()` in proxy before `check_input()`; `test_unicode_normalization_before_rails` integration test passes |
| INRL-02 | Plans 02, 03 | NeMo Guardrails content filter detects and blocks disallowed input topics | SATISFIED | `_run_nemo_rail("self_check_input", ...)` in `check_input()`; NeMo LLMRails initialized via `create_guardrail_engine()`; `test_content_filter_blocks` passes |
| INRL-03 | Plans 02, 03 | PII and secrets detected in input via presidio and rejected/redacted per policy | SATISFIED | `_check_pii_input()` uses `harness.pii.redactor.redact()`; `sensitive_data_input` rail triggers on PII; `test_pii_input_blocked` passes |
| INRL-04 | Plans 02, 03 | Prompt injection and jailbreak attempts detected and blocked | SATISFIED | `INJECTION_PATTERNS` (6 regexes) in `_check_injection_regex()`; `jailbreak_detection` rail via NeMo; `test_injection_regex_detected`, `test_injection_regex_variants` pass |
| INRL-05 | Plans 01, 03 | User can review, enable/disable, and tune thresholds for each input rail via config | SATISFIED | `rails.yaml` has `enabled`/`threshold`/`refusal_mode` per rail; `TenantConfig.rail_overrides` allows per-tenant overrides; `test_load_rails_config_valid`, `test_disabled_rail_skipped`, `test_threshold_permissive` pass |
| OURL-01 | Plans 02, 03 | Model output scanned for toxicity and bias before delivery | SATISFIED | `check_output()` runs `self_check_output` via NeMo; `test_toxic_output_blocked` passes |
| OURL-02 | Plans 02, 03 | Jailbreak-success patterns in output detected and blocked | SATISFIED | `jailbreak_output` rail in `check_output()`; `test_jailbreak_output_blocked` passes |
| OURL-03 | Plans 02, 03 | PII leakage in output detected and redacted | SATISFIED | `_check_pii_output()` uses redactor; `_build_redacted_response()` preserves response structure with redacted content; `test_pii_output_redacted` (unit) and `test_output_rail_blocks_pii` (integration) pass |
| OURL-04 | Plans 01, 03 | User can review, enable/disable, and tune thresholds for each output rail via config | SATISFIED | `rails.yaml` output rails (`self_check_output`, `jailbreak_output`, `sensitive_data_output`) all have `enabled`/`threshold`/`refusal_mode`; `TenantConfig.rail_overrides` supports per-tenant overrides |
| REFU-01 | Plans 02, 03 | Hard block mode: policy-violating requests return a principled refusal | SATISFIED | `_build_hard_block_refusal()` returns "violates our content policy"; proxy returns HTTP 400; `test_hard_block_returns_400` and `test_hard_block_refusal_content` pass |
| REFU-02 | Plans 02, 03 | Soft steer mode: borderline requests rewritten to allowed formulation | SATISFIED | `_build_soft_steer_messages()` prepends `SOFT_STEER_SYSTEM_PROMPT`; proxy makes second LiteLLM call; `test_soft_steer_messages` passes |
| REFU-03 | Plans 02, 03 | Informative refusal mode: explains why and offers safer adjacent help | SATISFIED | `_build_informative_refusal()` names rail and includes `_RAIL_SUGGESTIONS` per-rail; `test_informative_refusal_content` (unit + integration) pass |
| REFU-04 | Plans 01, 02, 03 | Refusal thresholds tunable from eval data | SATISFIED | Per-rail `threshold` float in `RailConfig`; `TenantConfig.rail_overrides` enables per-tenant threshold tuning; `test_threshold_permissive` verifies score/threshold comparison logic |

**All 13 Phase 6 requirements satisfied (INRL-01 through INRL-05, OURL-01 through OURL-04, REFU-01 through REFU-04).**

No orphaned requirements: REQUIREMENTS.md maps exactly these 13 IDs to Phase 6, all claimed by plans.

---

## Anti-Patterns Found

No blockers or warnings detected. Scanned all key Phase 6 files:

| File | Scan Result |
|------|-------------|
| `harness/guards/normalizer.py` | Clean — no TODOs, no empty implementations, no placeholder returns |
| `harness/guards/types.py` | Clean |
| `harness/guards/engine.py` | Clean — `# Phase 7` comment on line 253 (`cai_critique: None`) is intentional forward-reference, not a stub |
| `harness/config/rail_loader.py` | Clean |
| `harness/proxy/litellm.py` | Clean — `cai_critique: None` trace field is Phase 7 placeholder, correctly documented |
| `harness/main.py` | Clean |

---

## Human Verification Required

None. All integration tests prove the observable behaviors programmatically:
- Hard block: `test_hard_block_returns_400` confirms 400 status + "content policy" in response body
- Informative refusal: `test_informative_refusal_content` confirms rail name in response body
- Bypass: `test_bypass_tenant_skips_rails` confirms 200 for bypass tenant
- Output PII redaction: `test_output_rail_blocks_pii` confirms "[EMAIL]" replaces raw email
- Trace fields: `test_trace_guardrail_decisions_populated` and `test_trace_refusal_event_true` confirm SQLite records
- Unicode normalization: `test_unicode_normalization_before_rails` inspects body sent to LiteLLM transport

The only item requiring human observation in production is NeMo's live LLM-as-judge quality (whether the self-check model makes correct blocking decisions for novel harmful inputs). This is out of scope for unit/integration testing.

---

## Test Suite Results

```
80 passed, 1 skipped (NeMo hardware gate — expected in non-GPU environment)
```

Breakdown:
- `test_normalizer.py`: 9 tests — NFKC, zero-width, homoglyph, normalize_messages
- `test_rail_config.py`: 6 tests — Pydantic validation, YAML loading, all 3 refusal modes
- `test_guardrails.py`: 19 tests — all input/output rails, refusal modes, run-all-rails, threshold
- `test_proxy.py` (Phase 5 + Phase 6): 18 tests (10 Phase 5 + 8 Phase 6 integration)
- Other tests (phases 1-5): 28 tests — all still passing (no regressions)

---

## Commit Verification

All Phase 6 commits confirmed in git log:

| Commit | Plan | Description |
|--------|------|-------------|
| 7a04fa1 | 06-01 | feat: add normalizer, type contracts, rail config, and NeMo config files |
| 4958256 | 06-01 | test: add normalizer and rail config tests |
| 4886577 | 06-02 | test: add failing tests for GuardrailEngine (RED phase) |
| 042e67a | 06-02 | feat: implement GuardrailEngine with all rail types and refusal modes |
| 283cd8b | 06-03 | feat: wire GuardrailEngine into proxy route and lifespan |
| 6957097 | 06-03 | feat: add guardrail pipeline integration tests |

---

_Verified: 2026-03-22T08:00:00Z_
_Verifier: Claude (gsd-verifier)_
