# Roadmap: Model Store — Tiered Storage for DGX Spark

## Overview

Four phases take the project from a working configuration foundation through adapter-aware model enumeration, automated tiering automation, and finally to a complete user-facing CLI with status, revert, and documentation. Each phase delivers a coherent, independently verifiable capability that unblocks the next.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Foundation and Init** - Config infrastructure, shared library, and interactive init wizard (completed 2026-03-21)
- [ ] **Phase 2: Adapters and Usage Tracking** - HF and Ollama storage adapters, usage timestamp manifest, launcher hooks
- [ ] **Phase 3: Migration, Recall, and Safety** - Automated tiering cron, recall from cold, full safety envelope
- [ ] **Phase 4: CLI, Status, Revert, and Docs** - Unified CLI dispatcher, status/revert commands, documentation

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
**Plans**: TBD

Plans:
- [ ] 02-01: lib/hf_adapter.sh (whole-directory enumeration, size measurement, migrate/recall unit logic)
- [ ] 02-02: lib/ollama_adapter.sh (manifest parsing, blob ref-counting, server state check) and hooks/tracker.sh with launcher hook integration

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
**Plans**: TBD

Plans:
- [ ] 03-01: cmd/migrate.sh (flock, adapter dispatch, atomic symlink swap, dry-run, audit log) and cron/migrate_cron.sh
- [ ] 03-02: cmd/recall.sh (symlink detection, cold-to-hot, timer reset, interrupt-safe state file) and cron/disk_check_cron.sh with notify-send/log fallback

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
**Plans**: TBD

Plans:
- [ ] 04-01: bin/modelstore dispatcher, cmd/status.sh, cmd/revert.sh (interrupt-safe JSON state file, idempotent)
- [ ] 04-02: Progress bars (pv/rsync fallback), CLI-02 cron/sync scripts, headless hardening, docs update (README, CHANGELOG, .gitignore, example.bash_aliases)

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation and Init | 2/2 | Complete    | 2026-03-21 |
| 2. Adapters and Usage Tracking | 0/2 | Not started | - |
| 3. Migration, Recall, and Safety | 0/2 | Not started | - |
| 4. CLI, Status, Revert, and Docs | 0/2 | Not started | - |
