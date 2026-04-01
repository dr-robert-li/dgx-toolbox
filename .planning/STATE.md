---
gsd_state_version: 1.0
milestone: v1.1
milestone_name: Safety Harness
status: completed
stopped_at: "Checkpoint Task 2: 13-03-PLAN.md (awaiting human-verify)"
last_updated: "2026-04-01T03:37:51.664Z"
last_activity: "2026-04-01 — Completed 13-01-PLAN.md: GPU telemetry package scaffold, FailureClassifier, GPUSampler"
progress:
  total_phases: 13
  completed_phases: 13
  total_plans: 30
  completed_plans: 30
  percent: 33
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-24)

**Core value:** Models are always accessible regardless of which tier they're on while the hot drive never fills up with stale models.
**Current focus:** v1.2 Autoresearch Integration — Phase 11 ready for planning

## Current Position

Phase: 13 (GPU Telemetry Primitives) — in progress
Plan: 13-01 complete, 13-02 next
Status: Completed 13-01-PLAN.md
Last activity: 2026-04-01 — Completed 13-01-PLAN.md: GPU telemetry package scaffold, FailureClassifier, GPUSampler

Progress: [█░░░░░░░░░] 33% (v1.3, 1/3 plans)

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
- [Phase 07-03]: MIN_SAMPLE_SIZE=10 guard before judge call avoids noisy suggestions from small samples
- [Phase 07-03]: Judge JSON parse failure returns structured error dict (not exception) — admin endpoint and CLI never crash on bad model output
- [Phase 07-03]: _resolve_since() shared between admin.py and __main__.py — consistent shorthand handling
- [Phase 08-eval-harness-and-ci-gate]: eval_runs source CHECK constraint enforces only replay or lm-eval — invalid sources fail at DB level
- [Phase 08-eval-harness-and-ci-gate]: compute_metrics treats steer same as block for positive class — steered outputs count as correct refusals in F1 scoring
- [Phase 08-eval-harness-and-ci-gate]: run_replay batch-reads traces by timerange after all cases for guardrail_decisions — avoids per-request DB reads during evaluation
- [Phase 08-eval-harness-and-ci-gate]: check_regression uses separate safety_tolerance (2%) and capability_tolerance (5%) for metric category-specific enforcement
- [Phase 08-eval-harness-and-ci-gate]: HarnessLM uses conditional lm_eval import with try/except ImportError fallback to object base class — module loads safely without lm-eval installed
- [Phase 08-eval-harness-and-ci-gate]: render_trends falls back to plain text table when asciichartpy unavailable — no hard runtime dependency
- [Phase 09-red-teaming]: query_near_misses uses SQL pre-filter (refusal_event=0) then Python score>0 post-filter — avoids complex SQL JSON parsing while keeping DB reads bounded
- [Phase 09-red-teaming]: garak YAML profiles require plugins.generators.openai.OpenAICompatible.uri nesting — garak silently ignores wrong nesting
- [Phase 09-red-teaming]: check_balance evaluates combined active+pending total — balance enforced on final merged state not delta batch
- [Phase 09-red-teaming]: asyncio.Lock (not Semaphore) for single-job gate — lock.locked() is public API
- [Phase 09-red-teaming]: asyncio.create_task stored in app.state.redteam_active_task to prevent garbage collection
- [Phase 09-red-teaming]: garak runner uses asyncio.create_subprocess_exec not subprocess.run to avoid blocking event loop
- [Phase 10-01]: compute_priority uses 1.0 - min(distances) formula: closest-to-threshold items get highest priority
- [Phase 10-01]: SQL LEFT JOIN corrections pattern for reviewed status: single query, no N+1; rail_filter and hide_reviewed applied in Python post-processing
- [Phase 10-01]: CorrectionRequest Literal action enum gives FastAPI 422 validation before handler; hitl_router has no gradio import for headless API mode
- [Phase 10-02]: compute_calibration: midpoint when both approved+rejected; P95 for approved-only; min-0.05 for rejected-only
- [Phase 10-02]: export_jsonl edit action uses PII-redacted edited_response; falls back to cai_critique.revised_output then trace.response
- [Phase 10-02]: CLI __main__.py rewritten to match eval/__main__.py pattern: subparsers variable, _resolve_db_path, asyncio.run() for async commands
- [Phase 10-hitl-dashboard]: Gradio UI defaults to port 8501; sync httpx.Client used in callbacks; build_ui() returns Blocks without .launch()
- [Phase 11-01]: mapfile used to capture _discover_local_datasets output into array for nested select menu inside option 6 case
- [Phase 11-01]: HARNESS_API_KEY validated non-empty before health check with explicit warning against ci-runner key (bypass=true)
- [Phase 11-01]: screen-data.sh uses python3 json.dumps for safe JSON escaping of record content — not bash string manipulation
- [Phase 11-pipeline-wiring]: eval-checkpoint.sh points --gateway directly at temp vLLM on :8021 to measure raw model safety, not harness+model stack
- [Phase 11-pipeline-wiring]: String-append for LiteLLM config registration preserves comments; pyyaml round-trip for deregistration with timestamped backup
- [Phase 11-pipeline-wiring]: set +e/-e guards around subprocess calls when exit code capture is needed inside set -euo pipefail test scripts
- [Phase 12-demo-and-documentation]: Cycle-limiting via background log monitor plus time-based fallback avoids patching autoresearch train.py
- [Phase 13]: Root conftest.py path injection fixes namespace package collision between dgx-toolbox/telemetry/ directory and the installable telemetry package
- [Phase 13]: HANG classification never contains batch_cap per TELEM-14; prevents incorrect batch backoff on dataloader deadlocks
- [Phase 13]: nvmlDeviceGetMemoryInfo never called; /proc/meminfo MemAvailable is the authoritative memory source for GB10 UMA architecture
- [Phase 13-gpu-telemetry-primitives]: Tier classification based on raw_params not effective_params — raw model size determines hardware tier; effective_params used for memory headroom calculation
- [Phase 13-gpu-telemetry-primitives]: GPUSampler mock mode reads /proc/meminfo for memory — UMA architecture means memory is always available via procfs even without NVML
- [Phase 13-gpu-telemetry-primitives]: mock_pynvml fixture clears telemetry.sampler sys.modules cache before patching pynvml to prevent test ordering pollution from transitive imports
- [Phase 13-gpu-telemetry-primitives]: Bridge uses except Exception (not ImportError) to handle both import and runtime sampling failures in dgx_toolbox.py gpu_telemetry section

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

### v1.2 Architecture Decisions

- LiteLLM config at `~/.litellm/config.yaml` — model registration appends entries to this file
- Autoresearch launcher scripts already exist at `karpathy-autoresearch/` — Phase 11 adds config and glue, not a new launcher
- Safety eval hook invokes existing Phase 8 replay eval harness against checkpoints — no new eval infrastructure
- Training data screening routes through existing Phase 6 guardrail input check API — not a separate screening pipeline
- Model registration targets vLLM serving path — autoresearch checkpoints assumed HF-format

### Pending Todos

- ~~Verify NeMo Guardrails aarch64 pip install on DGX Spark in fresh venv before Phase 5 planning (Annoy C++ build risk)~~ RESOLVED 2026-03-22 — PASS on DGX Spark hardware
- Confirm port 8080 is not in use by code-server in target deployment
- Benchmark 7B judge model P95 latency on aarch64 before committing CAI async/sync split in Phase 7
- Confirm autoresearch checkpoint format (HF format assumed) before writing vLLM registration in Phase 11

### Quick Tasks Completed

| # | Description | Date | Commit | Status | Directory |
|---|-------------|------|--------|--------|-----------|
| 260322-m8z | autoresearch launcher with DGX Spark tuning and data source selection | 2026-03-22 | 5a8bb7e | Verified | [260322-m8z-autoresearch-launcher-with-dgx-spark-tun](./quick/260322-m8z-autoresearch-launcher-with-dgx-spark-tun/) |
| 260328-fkw | flexible extra bind mount support via EXTRA_MOUNTS env var in all container scripts | 2026-03-28 | 523ff20 | Verified | [260328-fkw-add-flexible-extra-bind-mount-support-to](./quick/260328-fkw-add-flexible-extra-bind-mount-support-to/) |

### Blockers/Concerns

- Phase 2: Ollama manifest JSON schema field paths not fully specified in research — verify with `cat ~/.ollama/models/manifests/...` on actual DGX before writing ollama_adapter.sh
- Phase 3: DBUS session address injection for notify-send from cron is MEDIUM confidence on aarch64 — test on actual machine before committing approach
- Phase 4: Revert state file JSON schema not yet specified — design during Phase 4 planning before writing revert.sh
- ~~Phase 5: NeMo Guardrails aarch64 Annoy build is the highest-risk dependency — must validate before writing any application code~~ RESOLVED 2026-03-22 — PASS confirmed on DGX Spark
- Phase 7: CAI judge model latency on DGX Spark aarch64 is unknown — async timeout values depend on actual hardware numbers
- Phase 9: deepteam 1.0.6 (March 2026) is newly released — feedback-loop red-teaming pattern is research-frontier; plan Phase 9 with a research step
- Phase 11: Confirm autoresearch checkpoint output format matches HF format expected by vLLM before writing registration script

## Session Continuity

Last session: 2026-04-01T03:37:48.739Z
Stopped at: Checkpoint Task 2: 13-03-PLAN.md (awaiting human-verify)
Resume file: None
Next action: `/gsd:plan-phase 11`
