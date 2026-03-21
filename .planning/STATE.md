---
gsd_state_version: 1.0
milestone: v1.1
milestone_name: Safety Harness
status: Roadmap defined — ready for Phase 5 planning
stopped_at: v1.1 roadmap created (phases 5–10, 39 requirements mapped)
last_updated: "2026-03-22"
last_activity: 2026-03-22 — v1.1 roadmap created
progress:
  total_phases: 10
  completed_phases: 4
  total_plans: 8
  completed_plans: 8
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

- Verify NeMo Guardrails aarch64 pip install on DGX Spark in fresh venv before Phase 5 planning (Annoy C++ build risk)
- Confirm port 8080 is not in use by code-server in target deployment
- Benchmark 7B judge model P95 latency on aarch64 before committing CAI async/sync split in Phase 7

### Blockers/Concerns

- Phase 2: Ollama manifest JSON schema field paths not fully specified in research — verify with `cat ~/.ollama/models/manifests/...` on actual DGX before writing ollama_adapter.sh
- Phase 3: DBUS session address injection for notify-send from cron is MEDIUM confidence on aarch64 — test on actual machine before committing approach
- Phase 4: Revert state file JSON schema not yet specified — design during Phase 4 planning before writing revert.sh
- Phase 5: NeMo Guardrails aarch64 Annoy build is the highest-risk dependency — must validate before writing any application code
- Phase 7: CAI judge model latency on DGX Spark aarch64 is unknown — async timeout values depend on actual hardware numbers
- Phase 9: deepteam 1.0.6 (March 2026) is newly released — feedback-loop red-teaming pattern is research-frontier; plan Phase 9 with a research step

## Session Continuity

Last session: 2026-03-22
Stopped at: v1.1 roadmap created (phases 5–10, 39 requirements mapped)
Resume file: None
Next action: `/gsd:plan-phase 5`
