---
phase: 07-constitutional-ai-critique
plan: "01"
subsystem: config
tags: [pydantic, yaml, constitution, guardrails, critique-threshold]

# Dependency graph
requires:
  - phase: 06-input-output-guardrails-and-refusal
    provides: RailConfig, load_rails_config, rails.yaml pattern
provides:
  - ConstitutionConfig and Principle Pydantic models with load_constitution()
  - Default constitution.yaml with 12 principles in 4 categories
  - critique_threshold field on RailConfig with cross-field validator
  - harness/critique/ package with public API exports
affects:
  - 07-02 (CritiqueEngine depends on ConstitutionConfig and Principle types)
  - 07-03 (Analyzer depends on critique_threshold field on RailConfig)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - Pydantic model_validator(mode='after') for cross-field validation
    - ConstitutionFile wrapper model for YAML root key (mirrors RailsFile/TenantsFile pattern)
    - TDD RED-GREEN-COMMIT cycle per task

key-files:
  created:
    - harness/critique/__init__.py
    - harness/critique/constitution.py
    - harness/config/constitution.yaml
    - harness/tests/test_constitution.py
  modified:
    - harness/config/rail_loader.py
    - harness/config/rails/rails.yaml
    - harness/tests/test_rail_config.py

key-decisions:
  - "critique_threshold is output-only — input rails have None; enforced by yaml structure, not code"
  - "critique_threshold >= threshold rejected at startup via model_validator — misconfiguration caught before any traffic"
  - "load_constitution() raises ValueError (not ValidationError) matching rail_loader.py contract — consistent error interface"

patterns-established:
  - "Constitution YAML follows same root-wrapper pattern as rails.yaml and tenants.yaml (ConstitutionFile.constitution)"
  - "Cross-field Pydantic validators use model_validator(mode='after') returning self for post-init validation"

requirements-completed: [CSTL-02, CSTL-04]

# Metrics
duration: 4min
completed: 2026-03-22
---

# Phase 7 Plan 01: Constitution Config and critique_threshold Foundation Summary

**Pydantic-validated constitution.yaml with 12 principles in 4 categories plus Optional[float] critique_threshold on RailConfig that rejects critique_threshold >= threshold at startup**

## Performance

- **Duration:** 4 min
- **Started:** 2026-03-22T11:41:13Z
- **Completed:** 2026-03-22T11:45:38Z
- **Tasks:** 2
- **Files modified:** 6

## Accomplishments

- Created harness/critique/ package with ConstitutionConfig, Principle, ConstitutionFile Pydantic models and load_constitution() following the rail_loader pattern exactly
- Shipped default constitution.yaml with 12 principles across safety, fairness, accuracy, and helpfulness categories
- Extended RailConfig with critique_threshold: Optional[float] and a model_validator that rejects critique_threshold >= threshold at startup with a clear error message
- Added critique_threshold values to output rails in rails.yaml; input rails remain without critique_threshold (None)
- 20 tests pass (8 new constitution tests + 6 new critique_threshold tests + 6 existing rail config tests)

## Task Commits

Each task was committed atomically (TDD: test commit then feat commit):

1. **Task 1 RED: Constitution tests** - `c5e68c6` (test)
2. **Task 1 GREEN: Constitution implementation** - `d09d26a` (feat)
3. **Task 2 RED: critique_threshold tests** - `0a09ec8` (test)
4. **Task 2 GREEN: critique_threshold implementation** - `851fde9` (feat)

_Note: TDD tasks have two commits each (test → feat)_

## Files Created/Modified

- `harness/critique/__init__.py` - Package init exporting ConstitutionConfig, Principle, ConstitutionFile, load_constitution
- `harness/critique/constitution.py` - Pydantic models and load_constitution() loader with ValueError on invalid YAML
- `harness/config/constitution.yaml` - 12 default principles (P-SAFETY-01 through P-HELPFULNESS-02), judge_model: default
- `harness/tests/test_constitution.py` - 8 tests covering load, validation, filtering, ordering, and default file
- `harness/config/rail_loader.py` - Added critique_threshold: Optional[float] = None and @model_validator cross-field validator
- `harness/config/rails/rails.yaml` - Added critique_threshold: 0.5 to self_check_output and jailbreak_output; 0.15 to sensitive_data_output
- `harness/tests/test_rail_config.py` - 6 new tests for critique_threshold validation and rails.yaml loading

## Decisions Made

- critique_threshold is output-rail-only — input rails have no critique_threshold; enforced by keeping it out of input rail YAML entries rather than by code guard (simpler, explicit)
- critique_threshold >= threshold rejected at startup via model_validator — misconfiguration caught before service accepts traffic, matching Phase 06 fail-fast philosophy
- load_constitution() raises ValueError (wrapping Pydantic ValidationError) matching load_rails_config() contract — consistent error interface across all config loaders

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- ConstitutionConfig, Principle types ready for 07-02 (CritiqueEngine)
- critique_threshold field on RailConfig ready for 07-03 (Analyzer risk-gating)
- Full test suite (94 passed, 1 skipped) confirms no regressions

---
*Phase: 07-constitutional-ai-critique*
*Completed: 2026-03-22*

## Self-Check: PASSED

- FOUND: harness/critique/__init__.py
- FOUND: harness/critique/constitution.py
- FOUND: harness/config/constitution.yaml
- FOUND: harness/tests/test_constitution.py
- FOUND: harness/config/rail_loader.py (modified)
- FOUND: harness/config/rails/rails.yaml (modified)
- FOUND: harness/tests/test_rail_config.py (modified)
- FOUND: .planning/phases/07-constitutional-ai-critique/07-01-SUMMARY.md
- Commits verified: e450e44 (test task1), d09d26a (feat task1), 2843eaa (test task2), 851fde9 (feat task2)
