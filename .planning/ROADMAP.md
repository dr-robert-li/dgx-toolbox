# Roadmap: Model Store — Tiered Storage for DGX Spark

## Overview

Four phases take the project from a working configuration foundation through adapter-aware model enumeration, automated tiering automation, and finally to a complete user-facing CLI with status, revert, and documentation. Each phase delivers a coherent, independently verifiable capability that unblocks the next.

v1.1 adds six more phases (5–10) delivering a full AI safety harness: gateway and trace foundation, NeMo guardrails, Constitutional AI critique, eval harness with CI gate, distributed red teaming, and an optional human-in-the-loop review dashboard.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

### v1.0 (Complete)

- [x] **Phase 1: Foundation and Init** - Config infrastructure, shared library, and interactive init wizard (completed 2026-03-21)
- [x] **Phase 2: Adapters and Usage Tracking** - HF and Ollama storage adapters, usage timestamp manifest, launcher hooks (completed 2026-03-21)
- [x] **Phase 3: Migration, Recall, and Safety** - Automated tiering cron, recall from cold, full safety envelope (completed 2026-03-21)
- [x] **Phase 4: CLI, Status, Revert, and Docs** - Unified CLI dispatcher, status/revert commands, documentation (completed 2026-03-21)

### v1.1 Safety Harness

- [ ] **Phase 5: Gateway and Trace Foundation** - Validated aarch64 environment, passthrough FastAPI gateway, auth, rate limiting, and PII-safe trace store
- [ ] **Phase 6: Input/Output Guardrails and Refusal** - NeMo Guardrails input/output rails, PII redaction, refusal calibration modes, user-tunable thresholds
- [ ] **Phase 7: Constitutional AI Critique** - Risk-gated two-pass critique pipeline, user-editable constitution, configurable judge model, AI-guided suggestions
- [ ] **Phase 8: Eval Harness and CI Gate** - Custom replay eval harness, lm-eval-harness integration, CI/CD promotion gate, trend dashboarding
- [ ] **Phase 9: Red Teaming** - Trace-driven adversarial prompt generation, garak scanning, deepteam feedback loop, Celery async dispatch
- [ ] **Phase 10: HITL Dashboard** - Gradio review UI, priority-sorted review queue, correction feedback loop, API-only headless mode

## Phase Details

### Phase 1: Foundation and Init
**Goal**: The project structure exists with a working config system, shared safety library, and an interactive init wizard that produces a validated config file all other scripts depend on
**Depends on**: Nothing (first phase)
**Requirements**: INIT-01, INIT-02, INIT-03, INIT-04, INIT-05, INIT-06, INIT-07, INIT-08
**Success Criteria** (what must be TRUE):
  1. User can run `modelstore init` and be guided through selecting hot/cold paths with a filesystem tree preview, confirming before any directories are created
  2. Init rejects a cold drive formatted as exFAT and requires ext4/xfs, explaining why
  3. After init, a config file exists on disk with retention period, cron schedule, and drive paths — all values match what the user entered
  4. User can run `modelstore init` again (reinit) to reconfigure drives, and existing model locations are shown with sizes before any migration begins
  5. Init scans and displays all existing HuggingFace and Ollama models with their sizes so the user sees what will be managed
**Plans:** 2/2 plans complete

Plans:
- [x] 01-01-PLAN.md — Project scaffold, lib/config.sh, lib/common.sh with mount check, space check, logging, and test infrastructure
- [ ] 01-02-PLAN.md — cmd/init.sh with gum/read-p fallback, filesystem validation, model scan, crontab, reinit support

### Phase 2: Adapters and Usage Tracking
**Goal**: HuggingFace and Ollama models can each be enumerated, sized, and individually identified, and every model load from a launcher updates a persistent usage timestamp
**Depends on**: Phase 1
**Requirements**: TRCK-01, TRCK-02, SAFE-01, SAFE-02, SAFE-06
**Success Criteria** (what must be TRUE):
  1. Running a vLLM, eval-toolbox, data-toolbox, or Unsloth launcher creates or updates a timestamp file for that model in `~/.modelstore/usage/`
  2. The cold drive mount state is checked before any operation that touches cold paths — unmounted drive produces a clear error, not a silent failure
  3. A space check with 10% safety margin is available as a shared function and correctly prevents operations when the destination is too full
  4. Ollama server running state is detected before any Ollama model operation, with a warning emitted if it is active
**Plans:** 2/2 plans complete

Plans:
- [ ] 02-01-PLAN.md — HF and Ollama storage adapters with full operation sets (list, size, path, migrate, recall) and safety guards
- [ ] 02-02-PLAN.md — Background watcher daemon (docker events + inotifywait) for zero-touch usage tracking with usage.json manifest

### Phase 3: Migration, Recall, and Safety
**Goal**: Stale models are moved to cold storage automatically on a cron schedule and recalled transparently when needed, with atomic symlinks, concurrency guards, and disk warnings keeping the system safe
**Depends on**: Phase 2
**Requirements**: MIGR-01, MIGR-02, MIGR-03, MIGR-04, MIGR-05, MIGR-06, MIGR-07, MIGR-08, RECL-01, RECL-02, RECL-03, SAFE-03, SAFE-04, SAFE-05
**Success Criteria** (what must be TRUE):
  1. After a model exceeds the retention period, the next cron run moves it to cold storage and replaces it with a symlink — vLLM and transformers continue loading from the same path without any change
  2. When a launcher detects a model is on cold storage, recall moves it back to hot and resets its timer before the model consumer is invoked — no manual intervention required
  3. Running two migration processes at the same time is prevented — the second invocation exits immediately with a clear message
  4. `modelstore migrate --dry-run` shows exactly which models would be moved without moving any data
  5. If either drive exceeds 98% usage, a desktop notification is sent — and if no desktop session is available, the warning is written to the log file instead
**Plans:** 2/2 plans complete

Plans:
- [ ] 03-01-PLAN.md — lib/audit.sh, Ollama adapter bodies, cmd/migrate.sh with stale detection + dry-run + flock + state file, cron/migrate_cron.sh, tests
- [ ] 03-02-PLAN.md — lib/notify.sh, cmd/recall.sh with usage reset, cron/disk_check_cron.sh with threshold alerting, watcher auto-recall trigger, tests

### Phase 4: CLI, Status, Revert, and Docs
**Goal**: All functionality is accessible through a single `modelstore` CLI, users can inspect the full tier state at a glance, fully revert tiering, and the project is documented
**Depends on**: Phase 3
**Requirements**: CLI-01, CLI-02, CLI-03, CLI-04, CLI-05, CLI-06, CLI-07, DOCS-01, DOCS-02, DOCS-03, DOCS-04
**Success Criteria** (what must be TRUE):
  1. `modelstore status` shows every tracked model with its tier (HOT/COLD/BROKEN SYMLINK), size, last-used timestamp, days until migration, and drive totals — covering both HuggingFace and Ollama models
  2. `modelstore revert` moves all cold models back to hot storage and removes all symlinks without deleting any model data — re-running it after an interruption completes safely from where it left off
  3. All commands produce correct output with no TTY — cron and NVIDIA Sync can invoke any script headlessly
  4. Large migrations and reverts show progress bars using pv or rsync --info=progress2 fallback
  5. README contains a modelstore section with aliases and NVIDIA Sync instructions; CHANGELOG has a release entry; .gitignore excludes runtime artifacts
**Plans:** 2/2 plans complete

Plans:
- [ ] 04-01-PLAN.md — cmd/status.sh (model table + dashboard) and cmd/revert.sh (interrupt-safe with --force, cleanup) with full test coverage
- [ ] 04-02-PLAN.md — Root reorganization into inference/data/eval/containers/setup subdirs, progress bar TTY guards, docs update (README, CHANGELOG, .gitignore, aliases)

### Phase 5: Gateway and Trace Foundation
**Goal**: Users can send requests through a validated, production-safe FastAPI gateway on aarch64 — with auth, rate limiting, LiteLLM proxying, and a PII-safe trace store — and NeMo Guardrails aarch64 compatibility is confirmed before any guardrail code is written
**Depends on**: Phase 4
**Requirements**: GATE-01, GATE-02, GATE-03, GATE-04, GATE-05, TRAC-01, TRAC-02, TRAC-03, TRAC-04
**Success Criteria** (what must be TRUE):
  1. `pip install nemoguardrails` succeeds in a fresh aarch64 venv on DGX Spark with Annoy built from source, and LLMRails instantiates at module load time (before uvicorn starts) without error
  2. POST /v1/chat/completions with a valid API key forwards to LiteLLM and returns the model response with less than 50ms added latency vs direct LiteLLM; GATE-05 bypass routes directly to LiteLLM
  3. A request with a missing or invalid API key receives 401; a tenant that exceeds its rate limit receives 429 — both without the model being called
  4. Every request writes a JSONL trace record to SQLite with request_id, tenant, timestamp, model, prompt, response, and all PII replaced by redaction tokens — raw PII is never written to the trace store
  5. Traces are queryable by request_id and by time range via the SQLite trace store
**Plans**: TBD

### Phase 6: Input/Output Guardrails and Refusal
**Goal**: All requests are screened before the model and all outputs are screened before delivery — with user-configurable per-rail thresholds and three distinct refusal modes — using Unicode-normalized input so guardrail evasion via encoding tricks is impossible
**Depends on**: Phase 5
**Requirements**: INRL-01, INRL-02, INRL-03, INRL-04, INRL-05, OURL-01, OURL-02, OURL-03, OURL-04, REFU-01, REFU-02, REFU-03, REFU-04
**Success Criteria** (what must be TRUE):
  1. A request containing zero-width characters or Unicode homoglyphs is normalized to NFC/NFKC before any classifier runs — an evasion attempt that bypasses the unnormalized classifier is blocked after normalization
  2. A request matching a content-filter rule, containing PII or secrets, or containing a detected prompt injection pattern is rejected at input — the model is never called and the trace records the block reason
  3. A model response containing toxicity, jailbreak-success indicators, or output PII is intercepted before delivery — the client receives a policy-appropriate response, not the raw model output
  4. A user edits a rail's threshold or enable flag in YAML config, restarts the service, and the changed behavior takes effect on the next request
  5. Hard block mode returns a principled refusal; soft steer mode rewrites the request and returns an allowed response; informative mode returns a refusal that explains why and offers adjacent help
**Plans**: TBD

### Phase 7: Constitutional AI Critique
**Goal**: Outputs that pass guardrails but score as high-risk trigger a two-pass critique-and-revise loop against a user-editable constitution — low-risk outputs are never touched — and the judge model can analyze trace history to produce actionable tuning suggestions
**Depends on**: Phase 6
**Requirements**: CSTL-01, CSTL-02, CSTL-03, CSTL-04, CSTL-05
**Success Criteria** (what must be TRUE):
  1. A high-risk output triggers a critique-revise cycle; the revised output is returned to the client and the trace record contains both the original output and the critique result
  2. A benign request results in exactly one model call — the critique loop is not triggered and the model call count is 1
  3. User edits `constitution.yaml`, restarts the service, and the new principles apply on the next high-risk request; a malformed constitution file causes a startup validation error before the service accepts traffic
  4. Judge model is set to a different model in config; a subsequent high-risk request's trace record shows the judge model identifier confirming the swap
  5. Querying trace history via the judge model produces a ranked list of guardrail and constitution tuning suggestions that the user can review and apply
**Plans**: TBD

### Phase 8: Eval Harness and CI Gate
**Goal**: Safety and capability regressions are caught before any model or config change is promoted — a replay harness scores refusal accuracy, lm-eval measures capability via correct endpoint routing, and CI blocks on any regression
**Depends on**: Phase 7
**Requirements**: EVAL-01, EVAL-02, EVAL-03, EVAL-04
**Success Criteria** (what must be TRUE):
  1. Running the replay harness against a curated safety/refusal dataset produces a score report (correct refusal rate, false refusal rate, F1) that matches expected baseline values for the reference config
  2. lm-eval generative tasks route through POST /v1/chat/completions and loglikelihood tasks route directly to LiteLLM — both paths complete without errors and produce plausible benchmark scores
  3. Lowering a refusal threshold below a known-bad prompt causes the CI gate to report a safety regression and exit non-zero, blocking promotion
  4. Each eval run's results are stored and a trend chart shows metric history across runs, making regressions and improvements visible over time
**Plans**: TBD

### Phase 9: Red Teaming
**Goal**: The harness mines its own failure history to generate adversarial prompts, runs garak one-shot vulnerability scans, executes deepteam feedback-loop generation, and dispatches all long-running jobs asynchronously — with dataset balance enforced in code
**Depends on**: Phase 8
**Requirements**: RDTM-01, RDTM-02, RDTM-03, RDTM-04
**Success Criteria** (what must be TRUE):
  1. A garak scan against the gateway endpoint completes and produces a vulnerability report showing which attack probes succeeded and which were blocked by guardrails
  2. The deepteam generator reads the trace store, identifies failure records, and writes adversarial prompt variants to a pending review queue — generated prompts require explicit promotion before entering eval datasets
  3. Submitting a red-team job via the API returns a job_id; polling job status shows running then complete; completed results are retrievable by job_id
  4. Before any generated dataset is written, a balance check enforces the configured ratio cap per attack category — datasets that would exceed the cap are rejected with a clear error
**Plans**: TBD

### Phase 10: HITL Dashboard
**Goal**: Operators can review flagged requests through a Gradio UI sorted by review priority, apply corrections that feed back into threshold calibration and fine-tuning data, and access the same workflow via API when no UI is available
**Depends on**: Phase 9
**Requirements**: HITL-01, HITL-02, HITL-03, HITL-04
**Success Criteria** (what must be TRUE):
  1. The Gradio dashboard on :8501 shows a review queue sorted by borderline classifier score — the most uncertain decisions appear first, not the oldest
  2. Clicking any queue item shows a side-by-side diff of the original model output vs the critique-revised output, and the reviewer can approve, reject, or edit the revision
  3. A reviewer correction is written to the corrections store, appears in the fine-tuning data export, and is reflected in threshold calibration on its next scheduled run
  4. The review queue and correction submission are fully accessible via REST API with no Gradio process running — headless mode produces identical corrections store entries
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation and Init | 2/2 | Complete | 2026-03-21 |
| 2. Adapters and Usage Tracking | 2/2 | Complete | 2026-03-21 |
| 3. Migration, Recall, and Safety | 2/2 | Complete | 2026-03-21 |
| 4. CLI, Status, Revert, and Docs | 2/2 | Complete    | 2026-03-21 |
| 5. Gateway and Trace Foundation | 0/? | Not started | - |
| 6. Input/Output Guardrails and Refusal | 0/? | Not started | - |
| 7. Constitutional AI Critique | 0/? | Not started | - |
| 8. Eval Harness and CI Gate | 0/? | Not started | - |
| 9. Red Teaming | 0/? | Not started | - |
| 10. HITL Dashboard | 0/? | Not started | - |
