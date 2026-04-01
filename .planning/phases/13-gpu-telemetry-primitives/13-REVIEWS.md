---
phase: 13
reviewers: [codex, gemini]
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

## Gemini Review

### Summary
The implementation strategy is technically sound and demonstrates a high degree of platform awareness, specifically regarding the unique constraints of the GB10 UMA architecture (Unified Memory, lack of `nvmlDeviceGetMemoryInfo` support, and reliance on `/proc/meminfo`). The phased approach correctly prioritizes the hardware abstraction and classification logic before moving into higher-level orchestration and integration. The inclusion of mock modes and comprehensive failure classification ensures the telemetry package will be testable in CI and useful for real-world training recovery.

### Strengths
- Platform Specificity: The explicit avoidance of `nvmlDeviceGetMemoryInfo` in favor of `/proc/meminfo` `MemAvailable` is a critical and correct architectural decision for the DGX Spark.
- Mock-First Development: Including `mock_pynvml` and `mock_meminfo` in the first wave (Plan 13-01) is essential for developing on non-DGX hardware and maintaining CI stability.
- Safety-Oriented Memory Modeling: The inclusion of a 5GB jitter in the headroom calculation and the explicit handling of `PermissionError` for `drop_caches` show a defensive programming mindset suitable for shared DGX environments.
- Deterministic Anchoring: The requirement for a locked 9-field hash order and SHA-256 hashing for configurations provides the necessary consistency for cross-run performance tracking.
- Classification Depth: Differentiating between `OOM`, `HANG`, `THERMAL`, and `PRESSURE` allows for more nuanced automated responses than a simple "failure" flag.

### Concerns
- HIGH: OOM Reference Leak Prevention — While the Architecture Decisions mention the PyTorch OOM retry pattern (outside `except` block), the plans do not explicitly define a helper or context manager to enforce this. There is a risk that consumers of `FailureClassifier` will implement the retry logic incorrectly, leading to tensor reference leaks.
- MEDIUM: Hash Field Underspecification — The plans mention a "9 field hash" but do not explicitly list the fields in the plan summary. Without a hardcoded list, different implementation waves might introduce field drift, breaking the "locked forever" requirement.
- MEDIUM: Permission Scoping — `drop_caches` requires root/sudo. If the toolbox is run in a rootless container or as a standard user, `UMAMemModel` baseline sampling will effectively skip this step. The plan handles the error, but it should perhaps log a warning that the "baseline is dirty."
- LOW: Hang Detection Latency — Ensure that the `GPUSampler` doesn't itself hang while trying to sample a device that is already in a TDR or "GpuLost" state.

### Suggestions
1. Add a task to Plan 13-01 to provide a decorator or context manager (e.g., `@telemetry.catch_oom`) that captures the OOM exception outside the except block.
2. In Plan 13-02, Task 2, explicitly list the 9 fields in a constant (e.g., `ANCHOR_HASH_FIELDS = [...]`) to prevent guesswork during implementation.
3. In Plan 13-01, Task 2, ensure the `append_jsonl` function includes schema validation to prevent malformed telemetry files from breaking downstream analysis.
4. If `drop_caches` fails, suggest a "Warmup" baseline method in `UMAMemModel` that allocates and frees a small tensor as fallback.

### Risk Assessment
**MEDIUM**. The risk is primarily driven by Hardware Specificity — any deviation from the `/proc/meminfo` strategy will lead to catastrophic OOMs or false headroom reporting. The plan is ready to proceed provided the 9-field hash schema is formalized before Plan 13-02 begins.

---

## Consensus Summary

### Agreed Strengths (2+ reviewers)
- Three-wave dependency sequencing is correct and supports incremental verification
- Mock mode introduced early enables CI and parallel development without GPU hardware
- Plans avoid scope creep; telemetry stays importable by external projects without forcing NVML/proc knowledge
- TDD approach is well-suited for behavior-heavy primitives
- HANG never returning batch_cap is correctly identified and locked down
- Platform-specific UMA decisions are correct and well-understood
- Defensive programming (PermissionError handling, 5 GB jitter margin)

### Agreed Concerns (2+ reviewers)
- **HIGH: Hash field list not explicit in plan summaries** — Both Codex and Gemini flag that the 9 fields for config_hash need to be frozen as a constant, not left implicit (note: the actual PLAN.md Task 2 does define HASH_FIELDS with all 9 fields — this is a summary-level visibility issue, not a plan gap)
- **HIGH: Partial failure degradation underspecified** — What happens when NVML init succeeds but individual metric reads fail? What shape does sample() return? (Codex). GPUSampler could hang on TDR/GpuLost device (Gemini).
- **HIGH: OOM retry pattern not enforced in code** — Architecture decision exists but no helper/decorator to prevent consumers from retrying inside except block (Gemini). Codex flags override precedence as underspecified.
- **MEDIUM: Persistence durability not addressed** — AnchorStore JSON writes could corrupt on interrupted process; no atomic write strategy (Codex)
- **MEDIUM: Integration error modes too coarse** — ImportError catch doesn't cover runtime sampling failures in the bridge (Codex)
- **MEDIUM: drop_caches skip should log a "dirty baseline" warning** — Both reviewers note this

### Divergent Views
- **OOM helper/decorator**: Gemini suggests adding a `@telemetry.catch_oom` context manager. This is out of scope for the telemetry package (it provides classification, not training loop management) but worth noting for downstream consumers.
- **Schema validation on append_jsonl**: Gemini suggests schema validation; Codex focuses on atomicity/flushing. Both are valid but neither is critical for v0.1.0.
- **Overall risk**: Codex rates Plan 13-02 as HIGH risk; Gemini rates overall MEDIUM. The difference is Codex focuses on policy specification sharpness while Gemini focuses on hardware correctness.

---

*Reviewed: 2026-04-01 by Codex (OpenAI) and Gemini (Google)*
*Claude CLI: empty output (separate session mode)*
