---
phase: 06-input-output-guardrails-and-refusal
plan: 01
subsystem: guardrails
tags: [nemoguardrails, pydantic, unicode, confusable-homoglyphs, langchain-openai, normalizer, colang]

# Dependency graph
requires:
  - phase: 05-gateway-and-trace-foundation
    provides: FastAPI gateway, TraceStore, PII redactor, NeMo compat probe
provides:
  - harness/guards/normalizer.py — NFKC normalization, zero-width stripping, homoglyph detection
  - harness/guards/types.py — GuardrailDecision and RailResult typed data contracts
  - harness/config/rail_loader.py — Pydantic-validated rails.yaml loader with startup-time validation
  - harness/config/rails/rails.yaml — 7 configured rails with enabled/threshold/refusal_mode
  - harness/config/rails/config.yml — NeMo Guardrails LLMRails.from_path() config
  - harness/config/rails/input_output.co — Colang 1.0 self-check input/output flow definitions
affects: [06-02-guardrail-engine, 06-03-refusal-handler, 07-constitutional-ai-critique]

# Tech tracking
tech-stack:
  added:
    - confusable-homoglyphs>=3.2 (Unicode homoglyph detection)
    - langchain-openai>=0.1 (LLM provider for NeMo Guardrails)
    - nemoguardrails>=0.21 (already installed from Phase 5, now in pyproject.toml)
  patterns:
    - "TDD RED/GREEN/REFACTOR cycle for all new modules"
    - "Pydantic BaseModel validation pattern from config/loader.py extended to rail_loader.py"
    - "normalize() always called before any classifier — zero-width + NFKC + homoglyph detection in one pass"
    - "load_rails_config() raises ValueError at startup, never silently falls back"

key-files:
  created:
    - harness/guards/normalizer.py
    - harness/guards/types.py
    - harness/config/rail_loader.py
    - harness/config/rails/rails.yaml
    - harness/config/rails/config.yml
    - harness/config/rails/input_output.co
    - harness/tests/test_normalizer.py
    - harness/tests/test_rail_config.py
  modified:
    - harness/pyproject.toml (added confusable-homoglyphs, langchain-openai, nemoguardrails)

key-decisions:
  - "normalize() strips zero-width chars AFTER NFKC (not before) so full-width zero-width chars normalize before stripping"
  - "normalize_messages() deduplicates flags across messages so each flag appears once even if multiple messages trigger it"
  - "config/rails/ is a config directory not a Python package — no __init__.py needed"
  - "confusable-homoglyphs 3.3.1 installed (>=3.2 required) — is_confusable returns list or False"

patterns-established:
  - "Normalizer pattern: text in -> (text_out, evasion_flags) out — flags flow into GuardrailDecision.evasion_flags"
  - "RailConfig follows TenantConfig pattern: Pydantic BaseModel + file-level model + load function that raises ValueError"
  - "Colang 1.0 flow pattern: define flow -> execute action -> bot refuse to respond on block"

requirements-completed: [INRL-01, INRL-05, OURL-04, REFU-04]

# Metrics
duration: 10min
completed: 2026-03-22
---

# Phase 6 Plan 01: Input/Output Guardrails Foundation Summary

**Unicode normalizer (NFKC + zero-width strip + homoglyph detect), GuardrailDecision/RailResult type contracts, Pydantic-validated rails.yaml loader, and NeMo Guardrails Colang config — all verified at startup time, 15 tests green**

## Performance

- **Duration:** 10 min
- **Started:** 2026-03-22T06:51:04Z
- **Completed:** 2026-03-22T07:01:00Z
- **Tasks:** 2 (TDD: RED + GREEN for each)
- **Files modified:** 9

## Accomplishments

- Unicode normalizer that catches all three evasion vectors (full-width chars, zero-width injection, homoglyphs) in a single pass before any classifier runs
- Typed data contracts (GuardrailDecision, RailResult) that Plan 02 GuardrailEngine and Plan 03 refusal handler will use as shared language
- Pydantic-validated rail config that rejects invalid configs at startup — `refusal_mode: bad` raises ValueError immediately, never at request time
- NeMo Guardrails config files (config.yml + input_output.co) ready for `LLMRails.from_path()` in Plan 02
- 15 tests covering all normalizer edge cases and all Pydantic validation failure modes

## Task Commits

Each task was committed atomically:

1. **Task 1: Create normalizer, type contracts, rail config, and NeMo config files** - `7a04fa1` (feat)
2. **Task 2: Tests for normalizer and rail config loading** - `4958256` (test)

**Plan metadata:** (docs commit — recorded after state updates)

_Note: TDD tasks have separate feat and test commits_

## Files Created/Modified

- `harness/guards/normalizer.py` - NFKC normalization, zero-width stripping (12 chars), homoglyph detection via confusable-homoglyphs
- `harness/guards/types.py` - GuardrailDecision and RailResult dataclasses with all fields Plan 02 needs
- `harness/config/rail_loader.py` - RailConfig/RailsFile Pydantic models + load_rails_config() that raises ValueError on bad config
- `harness/config/rails/rails.yaml` - 7 rails: self_check_input, jailbreak_detection, sensitive_data_input, injection_heuristic, self_check_output, jailbreak_output, sensitive_data_output
- `harness/config/rails/config.yml` - NeMo main model + sensitive_data_detection config + input/output flow references
- `harness/config/rails/input_output.co` - Colang 1.0: define flow self check input/output + bot refuse to respond
- `harness/tests/test_normalizer.py` - 9 tests covering NFKC, zero-width, homoglyph, normalize_messages, all 12 zero-width chars, multiple flags
- `harness/tests/test_rail_config.py` - 6 tests covering valid load, invalid mode, empty file, missing name, defaults, all 3 modes
- `harness/pyproject.toml` - Added confusable-homoglyphs>=3.2, langchain-openai>=0.1, nemoguardrails>=0.21

## Decisions Made

- `normalize()` applies NFKC first, then strips zero-width — ordering matters because full-width zero-width chars must be normalized to ASCII zero-width before the regex strips them
- `normalize_messages()` deduplicates flags so each flag appears at most once regardless of how many messages triggered it
- `harness/config/rails/` is a config directory, not a Python package — no `__init__.py` added (the plan explicitly noted this was optional and unnecessary)
- `confusable-homoglyphs` 3.3.1 is the latest available (plan required >=3.2); `is_confusable()` returns a list (truthy) or `False`

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

None — all dependencies were already available or installed cleanly. The `confusable-homoglyphs` package was not yet installed in the venv; installed before writing tests to verify API behavior first.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- All type contracts (GuardrailDecision, RailResult) are in place for Plan 02 GuardrailEngine
- `load_rails_config()` can be called at module load time in the GuardrailEngine — will fail fast on bad config
- NeMo config files are ready for `LLMRails.from_path("harness/config/rails/")` in Plan 02
- `normalize_messages()` is the first function to call in any guardrail pipeline — before PII redaction, before classifiers

---
*Phase: 06-input-output-guardrails-and-refusal*
*Completed: 2026-03-22*

## Self-Check: PASSED

- normalizer.py: FOUND
- types.py: FOUND
- rail_loader.py: FOUND
- rails.yaml: FOUND
- config.yml: FOUND
- input_output.co: FOUND
- test_normalizer.py: FOUND
- test_rail_config.py: FOUND
- Commit 7a04fa1: FOUND
- Commit 4958256: FOUND
