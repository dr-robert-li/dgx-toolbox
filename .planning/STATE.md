---
gsd_state_version: 1.0
milestone: v1.1
milestone_name: Safety Harness
status: Roadmap defined
stopped_at: Completed 07-02-PLAN.md
last_updated: "2026-03-22T11:33:58.403Z"
last_activity: 2026-03-22 — v1.1 roadmap created
progress:
  total_phases: 10
  completed_phases: 6
  total_plans: 17
  completed_plans: 16
  percent: 0
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-22)

**Core value:** Models are always accessible regardless of which tier they're on while the hot drive never fills up with stale models.
**Current focus:** v1.1 Safety Harness — roadmap defined, ready to plan Phase 5

## Current Position

Phase: 5 (not started)
Plan: —
Status: Roadmap defined
Last activity: 2026-03-22 — v1.1 roadmap created

Progress: [░░░░░░░░░░] 0% (v1.1)

## v1.1 Phase Map

| Phase | Name | Requirements | Status |
|-------|------|--------------|--------|
| 5 | Gateway and Trace Foundation | GATE-01–05, TRAC-01–04 | Not started |
| 6 | Input/Output Guardrails and Refusal | INRL-01–05, OURL-01–04, REFU-01–04 | Not started |
| 7 | Constitutional AI Critique | CSTL-01–05 | Not started |
| 8 | Eval Harness and CI Gate | EVAL-01–04 | Not started |
| 9 | Red Teaming | RDTM-01–04 | Not started |
| 10 | HITL Dashboard | HITL-01–04 | Not started |

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- Symlinks over hard links (cross-filesystem requirement)
- Configurable hot/cold at init (user may swap drives later)
- Bash only, no Python (host execution, minimize dependencies)
- Single modelstore CLI + individual cron scripts (interactive vs headless separation)
- PASS=$((PASS+1)) not ((PASS++)) in bash test scripts with set -e (arithmetic expansion returns exit code 1 when result is 0)
- validate_cold_fs returns 1 not exit 1 (callers handle rejection gracefully)
- No bats dependency — inline bash assertion pattern runs everywhere
- [Phase 01-foundation-and-init]: Hot paths auto-detected via HF Python API and Ollama /api/tags rather than user-entered — eliminates user-entry errors and handles non-standard install paths
- [Phase 01-foundation-and-init]: validate_cold_fs extended to accept network/cloud mounts (nfs, nfs4, cifs, fuse.sshfs, fuse.rclone, fuse.s3fs, fuse.gcsfuse) for NAS/cloud cold storage
- [Phase 01-foundation-and-init]: Cron install skips gracefully if Phase 3 scripts not yet present — init safe to run before Phase 3
- [Phase 02-adapters-and-usage-tracking]: hf_migrate_model symlink-already-migrated check placed BEFORE mount/space guards (idempotent re-run works without cold drive mounted)
- [Phase 02-adapters-and-usage-tracking]: Ollama migrate/recall stubs defer actual ollama cp/rm to Phase 3 — guards are complete (SAFE-06 block, SAFE-01 mount, SAFE-02 space)
- [Phase 02-adapters-and-usage-tracking]: Test comment strings avoid grep pattern words (sudo, set -e) to keep acceptance criteria grep checks from matching comments
- [Phase 02-adapters-and-usage-tracking]: Function definitions copied inline in test file rather than sourcing watcher.sh — avoids BASH_SOURCE path resolution issues with process substitution
- [Phase 02-adapters-and-usage-tracking]: ms_track_usage debounce reads last timestamp before acquiring flock to avoid contention on frequent access events
- [Phase 02-adapters-and-usage-tracking]: Daemon uses wait -n with fallback to wait so either watcher subprocess exiting terminates the parent daemon
- [Phase 03-migration-recall-and-safety]: Ollama recall derives cold_base by following hot blob symlink via readlink — more robust than requiring cold_base as parameter
- [Phase 03-migration-recall-and-safety]: cron_output unbound variable with set -uo pipefail fixed by tee to temp file instead of command substitution with background process
- [Phase 03-migration-recall-and-safety]: find_stale_hf_models checks symlink status in both usage.json and directory walk paths to avoid re-migrating already-migrated models
- [Phase 03-migration-recall-and-safety]: Test RECL-03 launcher_hook sets COLD_PATH directly ($TMP/cold) instead of calling load_config to avoid reading real system config
- [Phase 03-migration-recall-and-safety]: check_disk_threshold inlined in test-disk-check.sh to allow df/notify_user mocking as shell functions without subprocess complications
- [Phase 04-cli-status-revert-and-docs]: status.sh uses find -maxdepth 1 (not hf_list_models Python API) to detect all tiers including BROKEN dangling symlinks
- [Phase 04-cli-status-revert-and-docs]: revert.sh completed_models JSON array in op_state.json enables interrupt-safe multi-model tracking via _append_completed/_is_completed helpers
- [Phase 04-cli-status-revert-and-docs]: test-revert.sh mock pattern: generate mock_cmd/revert.sh with inline check_cold_mounted override + tail -n +21 for body (common.sh uses mountpoint -q which fails in temp dirs)
- [Phase 04-cli-status-revert-and-docs]: rsync_flags variable approach for TTY guard in adapter rsync calls — cleaner than inline substitution
- [Phase 04-cli-status-revert-and-docs]: Mock rsync in test-hf-adapter.sh must preserve directory structure (cp -r), not just mkdir destination
- [Phase 04-cli-status-revert-and-docs]: modelstore.sh stays in root alongside status.sh and lib.sh (not moved to subdirectory)
- [Phase 05-gateway-and-trace-foundation]: importlib.import_module() for NeMo probe avoids top-level ImportError in environments without nemoguardrails installed
- [Phase 05-gateway-and-trace-foundation]: FastAPI 0.135 HTTPBearer returns 401 not 403 for missing credentials — test accepts both for version tolerance
- [Phase 05-gateway-and-trace-foundation]: TPM limiting has one-request lag by design: record_tpm post-response with actual count; check_tpm gates next request
- [Phase 05-gateway-and-trace-foundation]: SlidingWindowLimiter uses asyncio.Lock() — harness runs under uvicorn single asyncio event loop
- [Phase 05-gateway-and-trace-foundation]: NeMo/Presidio tests use pytest.skip() not pytest.fail() when library unavailable — enables safe CI runs without aarch64 hardware
- [Phase 05-gateway-and-trace-foundation]: aarch64 GO: NeMo Guardrails + Annoy C++ build + Presidio spaCy NER all PASS on DGX Spark — Phase 6 guardrail implementation unblocked
- [Phase 05-gateway-and-trace-foundation]: Regex pre-pass before Presidio NER ensures structured PII (email/phone/SSN/CC) always redacted even without spaCy model
- [Phase 05-gateway-and-trace-foundation]: BackgroundTask for trace write decouples response latency from SQLite I/O
- [Phase 05-gateway-and-trace-foundation]: CLI trace query interface deferred — Python TraceStore API satisfies TRAC-04
- [Phase 06-01]: normalize() strips zero-width chars AFTER NFKC so full-width zero-width chars normalize before stripping
- [Phase 06-01]: normalize_messages() deduplicates flags across messages — each flag appears once even if multiple messages trigger it
- [Phase 06-01]: load_rails_config() raises ValueError at startup, never silently falls back — invalid config fails fast
- [Phase 06-input-output-guardrails-and-refusal]: GuardrailEngine uses run-all-rails aggregation (not fail-fast) — all enabled rails run and all results collected before determining block status
- [Phase 06-input-output-guardrails-and-refusal]: sensitive_data_output block returns Presidio-redacted content (not generic refusal) — preserves response utility while protecting PII
- [Phase 06-input-output-guardrails-and-refusal]: Presidio balanced mode detects LOCATION entities; tests use numeric content to avoid false PII hits in clean-output assertions
- [Phase 06-input-output-guardrails-and-refusal]: getattr(app.state, 'guardrail_engine', None) guard ensures backward compatibility — existing tests without guardrail_engine on app.state still pass
- [Phase 07-01]: critique_threshold >= threshold rejected at startup via model_validator — misconfiguration caught before any traffic
- [Phase 07-01]: load_constitution() raises ValueError matching load_rails_config() contract — consistent error interface across all config loaders
- [Phase 07-01]: critique_threshold is output-rail-only by YAML convention — input rails have None by omission, no code guard needed
- [Phase 07-02]: CritiqueEngine re-checks revision against critique_threshold (not threshold) — revision just needs to drop below critique level, not be fully clean
- [Phase 07-02]: _MinimalTenant with pii_strictness=minimal used for revision re-check to avoid double-redacting

### v1.1 Architecture Decisions (Pre-Phase 5)

- FastAPI gateway on port 8080 (verify code-server not running before assigning)
- NeMo Guardrails imported in-process as library — not a sidecar
- LLMRails MUST be instantiated at module top level before uvicorn.run(), never inside async handler
- No uvloop — nest_asyncio cannot patch uvloop C extension; pin asyncio event loop explicitly
- Unicode NFC/NFKC normalization + zero-width stripping is the first preprocessing step, before every classifier
- PII redaction pass happens before trace record is written — raw PII never lands in SQLite
- CAI critique is risk-gated — only triggered for high-risk outputs, not unconditional
- lm-eval loglikelihood tasks route to LiteLLM directly, not through POST /v1/chat/completions
- Red teaming requires stable trace data — cannot start before Phase 8 (eval harness) is complete
- HITL dashboard requires eval harness and red team data — must come last (Phase 10)

### Pending Todos

- ~~Verify NeMo Guardrails aarch64 pip install on DGX Spark in fresh venv before Phase 5 planning (Annoy C++ build risk)~~ RESOLVED 2026-03-22 — PASS on DGX Spark hardware
- Confirm port 8080 is not in use by code-server in target deployment
- Benchmark 7B judge model P95 latency on aarch64 before committing CAI async/sync split in Phase 7

### Quick Tasks Completed

| # | Description | Date | Commit | Status | Directory |
|---|-------------|------|--------|--------|-----------|
| 260322-m8z | autoresearch launcher with DGX Spark tuning and data source selection | 2026-03-22 | 5a8bb7e | Verified | [260322-m8z-autoresearch-launcher-with-dgx-spark-tun](./quick/260322-m8z-autoresearch-launcher-with-dgx-spark-tun/) |

### Blockers/Concerns

- Phase 2: Ollama manifest JSON schema field paths not fully specified in research — verify with `cat ~/.ollama/models/manifests/...` on actual DGX before writing ollama_adapter.sh
- Phase 3: DBUS session address injection for notify-send from cron is MEDIUM confidence on aarch64 — test on actual machine before committing approach
- Phase 4: Revert state file JSON schema not yet specified — design during Phase 4 planning before writing revert.sh
- ~~Phase 5: NeMo Guardrails aarch64 Annoy build is the highest-risk dependency — must validate before writing any application code~~ RESOLVED 2026-03-22 — PASS confirmed on DGX Spark
- Phase 7: CAI judge model latency on DGX Spark aarch64 is unknown — async timeout values depend on actual hardware numbers
- Phase 9: deepteam 1.0.6 (March 2026) is newly released — feedback-loop red-teaming pattern is research-frontier; plan Phase 9 with a research step

## Session Continuity

Last session: 2026-03-22T11:33:58.402Z
Stopped at: Completed 07-02-PLAN.md
Resume file: None
Next action: `/gsd:plan-phase 5`
