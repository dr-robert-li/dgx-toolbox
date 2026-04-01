---
phase: 13
reviewers: [codex]
reviewed_at: 2026-04-01T12:00:00Z
plans_reviewed: [13-01-PLAN.md, 13-02-PLAN.md, 13-03-PLAN.md]
---

# Cross-AI Plan Review — Phase 13

## Codex Review

### Plan 13-01 Review

#### Summary
Plan 13-01 is a strong first wave. It front-loads the two highest-leverage primitives, `FailureClassifier` and `GPUSampler`, and correctly treats mock mode and UMA memory sourcing as first-class requirements rather than follow-up work. The scope is appropriate for an initial wave, but the plan is light on a few edge conditions that will matter immediately: partial NVML availability, malformed `/proc/meminfo`, atomicity of NDJSON appends, and exact failure-shape guarantees for `sample()` output.

#### Strengths
- Builds the right foundation first: classification and sampling unblock all downstream components.
- Dependency order is sound; later work depends directly on sampler and failure outputs.
- TDD focus is appropriate for behavior-heavy primitives.
- Explicitly avoids `nvmlDeviceGetMemoryInfo` and subprocesses, matching the DGX Spark UMA constraint.
- Mock mode on NVML init failure is the right CI-safe baseline.
- Calls out `HANG` never returning `batch_cap`, which is an important invariant to lock down early.

#### Concerns
- HIGH: "mock mode when `nvmlInit` fails" may be too narrow. Real systems can also fail later during handle acquisition or individual metric reads; the plan does not say whether those also degrade cleanly.
- HIGH: TELEM-03 requires `sample()` to return a complete dict, but the plan does not define completeness under partial telemetry failure. Missing keys vs `None` values should be specified and tested.
- MEDIUM: `_read_meminfo` is mentioned, but there is no explicit coverage for malformed, missing, or permission-denied `/proc/meminfo` reads.
- MEDIUM: `append_jsonl()` is specified as append-only NDJSON, but there is no mention of file creation semantics, encoding, flushing, or concurrent append behavior.
- MEDIUM: The plan says "never calls `nvmlDeviceGetMemoryInfo`," but that needs enforcement via tests or mocks that fail if called.
- LOW: Package scaffold is mentioned only briefly; it is unclear whether installability/import-path checks are included in this wave or deferred.

#### Suggestions
- Specify `sample()` schema now: fixed keys always present, with explicit sentinel values on degraded reads.
- Add tests for partial NVML failure after successful init: handle lookup failure, power unsupported, temp unsupported, util unsupported.
- Add tests for `/proc/meminfo` parsing failures and verify error classification or fallback behavior.
- Make `append_jsonl()` behavior explicit: UTF-8, newline-terminated records, create parent/file if needed, append atomically as far as practical.
- Add a negative test that explodes if `nvmlDeviceGetMemoryInfo` is invoked.
- Include a minimal editable-install/import smoke test in this wave if package scaffolding is being created here.

#### Risk Assessment
**MEDIUM**. The wave is well-scoped and aligned with the phase goal, but sampler behavior is foundational; if the error model and output contract are underspecified here, every downstream component will inherit ambiguity.

---

### Plan 13-02 Review

#### Summary
Plan 13-02 covers the core decision logic of the telemetry package and is mostly decomposed well: memory modeling and scaling in one task, persistence and probe orchestration in the next. It directly addresses the major functional requirements, but this wave carries the highest correctness risk because it encodes operational policy: headroom math, tier assignment, persistence invariants, override precedence, and probe commit/revert logic. Those need tighter specification than the current plan text shows.

#### Strengths
- Good separation between "compute policy" and "stateful orchestration."
- Includes the critical DGX Spark-specific constraints: 5 GB jitter margin, `pin_memory=False`, `prefetch_factor<=4`.
- Captures the locked `config_hash` concept and 7-day expiry, which are key to reproducible anchor behavior.
- Correctly keeps HANG handling conservative by excluding `batch_cap`.
- ProbeProtocol is placed after AnchorStore, which matches real dependency flow.

#### Concerns
- HIGH: The 9 fields used for `config_hash` are not named in the plan summary. Without locking the exact field list and order in tests/docs, TELEM-09 is easy to implement incorrectly.
- HIGH: Override rule precedence is underspecified. If a config has both a prior `COMPLETED` and later `OOM`/`WATCHDOG`, or multiple records with different timestamps, the plan does not state how precedence is resolved.
- HIGH: `sample_baseline()` includes dropping page cache, but the plan only mentions `PermissionError` handling. It should also define behavior for non-Linux paths, read-only `/proc/sys/vm/drop_caches`, and partial execution failures.
- HIGH: `evaluate_probe()` returning commit/revert based on peak memory comparison is too vague. The threshold logic, comparison baseline, and safe-threshold semantics need to be explicit or downstream behavior will drift.
- MEDIUM: EffectiveScale mentions multiplier tables, but not how conflicting modifiers compose, round, or clamp across tiers.
- MEDIUM: No explicit tests are called out for expiry edge cases: exact 7-day boundary, clock skew, corrupted JSON, empty store, duplicate records.
- MEDIUM: JSON persistence can be corrupted by interrupted writes; no mention of atomic write strategy or recovery behavior.
- LOW: There is some coupling risk between AnchorStore record format and ProbeProtocol output schema if both evolve in the same wave without a fixed contract.

#### Suggestions
- Explicitly define and test the 9 `config_hash` fields and their exact serialization order now. This should be treated as a permanent compatibility contract.
- Add a written precedence matrix for anchor overrides: newest record wins vs severity wins vs status-specific rules.
- Define exact `sample_baseline()` behavior when cache dropping is unavailable: warn-and-continue vs fail-hard.
- Tighten `evaluate_probe()` semantics: what inputs are required, what constitutes commit vs revert, and whether "equal peak memory" commits.
- Add corruption-handling tests for AnchorStore: invalid JSON, truncated file, unknown statuses, stale entries.
- Use atomic persistence semantics for AnchorStore writes if the implementation will update the JSON file in place.
- Add boundary tests for tier thresholds and for multiplier composition in EffectiveScale.

#### Risk Assessment
**HIGH**. This wave encodes most of the project's operational policy. Small ambiguities here can produce wrong batch ceilings, unstable probes, or non-reproducible anchors, which directly undermines the phase goal.

---

### Plan 13-03 Review

#### Summary
Plan 13-03 is intentionally small and appropriately defers integration until the core telemetry primitives exist. The bridge strategy is pragmatic: optional import in `dgx_toolbox.py` and conditional reporting in `status.sh`. The main risk is not implementation complexity but under-testing the integration boundary, especially around installation state, partial package availability, and shell/Python output consistency.

#### Strengths
- Keeps integration thin instead of pushing logic into `dgx_toolbox.py` or shell code.
- `try/except ImportError` is the right pattern for optional telemetry availability.
- Includes a human verification checkpoint for `status.sh`, which is reasonable for formatting-sensitive output.
- Directly maps to TELEM-16 and TELEM-17 without obvious over-engineering.

#### Concerns
- HIGH: `ImportError` handling may be too coarse. If telemetry imports succeed but runtime sampling fails, the bridge still needs graceful degradation; the plan does not say how that is surfaced.
- MEDIUM: `status.sh` conditional behavior is mentioned, but no contract is given for timeouts, exit codes, or malformed telemetry output from the Python side.
- MEDIUM: Only "bridge test" is named; there should be distinct tests for telemetry absent, telemetry installed but sampler unavailable, and telemetry installed with mock output.
- MEDIUM: Human verification of formatting is useful, but relying on it for core integration correctness leaves regression risk.
- LOW: The wave assumes the package is already installable and discoverable in the runtime environment; if editable install behavior varies, integration may fail in ways not covered here.

#### Suggestions
- Test three explicit modes in integration: package missing, package present with successful sample, package present with sampling exception.
- Make `status_report()` return a stable `gpu_telemetry` shape even when telemetry is unavailable or degraded.
- Define what `status.sh` prints when import succeeds but sampling fails; do not collapse all failures into "sampler not installed."
- Add a non-human automated assertion for the presence/absence of the `GPU TELEMETRY` block in `status.sh`.
- Ensure the integration never hard-fails the broader status command because telemetry is optional.

#### Risk Assessment
**MEDIUM**. The scope is controlled, but integration failures are user-visible and easy to miss if testing only covers the happy path and "package absent" path.

---

## Consensus Summary

### Agreed Strengths
- Three-wave dependency sequencing is correct and supports incremental verification
- Mock mode introduced early enables CI and parallel development without GPU hardware
- Plans avoid scope creep; telemetry stays importable by external projects without forcing NVML/proc knowledge
- TDD approach is well-suited for behavior-heavy primitives
- HANG never returning batch_cap is correctly identified and locked down

### Agreed Concerns
- **HIGH: Permanent compatibility contracts are implied but not frozen** — sampler output schema, anchor record schema, hash field list/order need explicit locking
- **HIGH: Override rule precedence underspecified** — newest-wins vs severity-wins for anchor records with conflicting statuses
- **HIGH: Partial failure degradation underspecified** — what happens when NVML init succeeds but individual metric reads fail? What shape does sample() return?
- **MEDIUM: Persistence durability not addressed** — AnchorStore JSON writes could corrupt on interrupted process; no atomic write strategy
- **MEDIUM: Integration error modes too coarse** — ImportError catch doesn't cover runtime sampling failures in the bridge

### Divergent Views
N/A — single reviewer (Gemini CLI unavailable)

---

*Reviewed: 2026-04-01 by Codex (OpenAI)*
*Gemini: unavailable (CLI exit 41)*
