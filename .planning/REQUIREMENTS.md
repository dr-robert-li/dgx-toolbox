# Requirements: DGX Toolbox

**Defined:** 2026-03-21 (v1.0), 2026-03-22 (v1.1)
**Core Value:** Models are always accessible regardless of which tier they're on while the hot drive never fills up with stale models.

## v1.0 Requirements (Complete)

### Initialization

- [x] **INIT-01**: User can run interactive init wizard that shows filesystem tree and selects hot/cold drives and paths
- [x] **INIT-02**: Init creates directory structure on both drives with user confirmation
- [x] **INIT-03**: User can configure retention period (default 14 days) during init
- [x] **INIT-04**: User can configure cron schedule (default 2 AM) during init
- [x] **INIT-05**: Init persists all settings to a config file on disk
- [x] **INIT-06**: Init validates cold drive filesystem (rejects exFAT, requires ext4/xfs)
- [x] **INIT-07**: Init scans existing models and shows what's where with sizes
- [x] **INIT-08**: User can reinitialize to different drives with progress bars for migration and garbage collection on old paths

### Migration

- [x] **MIGR-01**: Daily cron job migrates models unused beyond retention period from hot to cold store using rsync
- [x] **MIGR-02**: Migrated models are replaced with symlinks so all paths remain valid
- [x] **MIGR-03**: Symlink replacement is atomic (ln + mv -T pattern, no broken window)
- [x] **MIGR-04**: HuggingFace models are migrated as whole `models--*/` directories to preserve internal relative symlinks
- [x] **MIGR-05**: Ollama models are migrated with manifest-aware blob reference counting (shared blobs not moved if still referenced)
- [x] **MIGR-06**: Concurrent migrations are prevented via flock
- [x] **MIGR-07**: User can run dry-run mode to see what would migrate without moving data
- [x] **MIGR-08**: All migration and recall operations are logged to an audit file

### Recall

- [x] **RECL-01**: When a model is actively needed, it is moved back from cold to hot store automatically
- [x] **RECL-02**: Recall replaces the symlink with real files and resets the retention timer
- [x] **RECL-03**: Launcher hooks in vLLM, eval-toolbox, data-toolbox, and Unsloth scripts trigger recall and update usage timestamps

### Usage Tracking

- [x] **TRCK-01**: Usage tracker maintains a timestamp manifest file per model, updated on every load
- [x] **TRCK-02**: Existing DGX Toolbox launcher scripts (vLLM, eval-toolbox, data-toolbox, Unsloth) are hooked to call the usage tracker

### Safety

- [x] **SAFE-01**: Migration refuses to create symlinks if cold drive is not mounted (verified via `mountpoint -q`)
- [x] **SAFE-02**: Migration checks available space on destination drive with 10% safety margin before moving
- [x] **SAFE-03**: Cron job sends desktop notification via `notify-send` if either drive exceeds 98% usage
- [x] **SAFE-04**: Notifications fall back to log file when desktop session is unavailable
- [x] **SAFE-05**: All multi-step operations use a state file for interrupt-safe, idempotent resumption
- [x] **SAFE-06**: Ollama server state is checked before migrating Ollama models (warn if running)

### CLI & Operations

- [x] **CLI-01**: Single `modelstore` CLI entry point dispatches to subcommands: init, status, recall, revert, migrate
- [x] **CLI-02**: Individual scripts exist for cron and NVIDIA Sync integration
- [x] **CLI-03**: `modelstore status` shows what's on each tier with sizes, last-used timestamps, and space available
- [x] **CLI-04**: `modelstore revert` moves all models back to internal, removes all symlinks, undoes all tiering
- [x] **CLI-05**: Revert is interrupt-safe and idempotent (can be re-run if interrupted)
- [x] **CLI-06**: Large migrations show progress bars (pv/rsync --info=progress2)
- [x] **CLI-07**: Non-interactive commands work headless for NVIDIA Sync (no TTY required)

### Documentation

- [x] **DOCS-01**: README updated with modelstore section, aliases, and NVIDIA Sync instructions
- [x] **DOCS-02**: CHANGELOG updated with modelstore release entry
- [x] **DOCS-03**: .gitignore updated for modelstore runtime artifacts
- [x] **DOCS-04**: example.bash_aliases updated with modelstore aliases

## v1.1 Requirements — Safety Harness

Requirements for the AI safety harness milestone. Each maps to roadmap phases.

### Gateway & Routing

- [x] **GATE-01**: User can send POST /v1/chat/completions requests through the safety harness gateway
- [x] **GATE-02**: User authenticates via API key with per-tenant identity attached to each request
- [x] **GATE-03**: Requests are rate-limited per tenant with configurable limits
- [x] **GATE-04**: Gateway proxies to LiteLLM for model-agnostic model invocation
- [x] **GATE-05**: User can bypass the harness and route directly to LiteLLM when safety pipeline is not needed

### Input Guardrails

- [x] **INRL-01**: Input is normalized (Unicode NFC/NFKC + zero-width character stripping) before any classifier runs
- [x] **INRL-02**: NeMo Guardrails content filter detects and blocks disallowed input topics
- [x] **INRL-03**: PII and secrets are detected in input via presidio and rejected or redacted per policy
- [x] **INRL-04**: Prompt injection and jailbreak attempts are detected and blocked
- [x] **INRL-05**: User can review, enable/disable, and tune thresholds for each input rail via config

### Output Guardrails

- [x] **OURL-01**: Model output is scanned for toxicity and bias before delivery
- [x] **OURL-02**: Jailbreak-success patterns in output are detected and blocked
- [x] **OURL-03**: PII leakage in output is detected and redacted
- [x] **OURL-04**: User can review, enable/disable, and tune thresholds for each output rail via config

### Constitutional AI

- [x] **CSTL-01**: Flagged outputs go through a two-pass critique→revise pipeline against constitutional principles
- [x] **CSTL-02**: Constitutional principles are user-editable via YAML config, validated on startup
- [x] **CSTL-03**: Judge model is configurable (default same-model, swappable to dedicated judge)
- [x] **CSTL-04**: CAI critique is risk-gated — only triggered for outputs classified as high-risk by output rails
- [x] **CSTL-05**: Judge model provides AI-guided suggestions for guardrail and constitution tuning based on trace history

### Refusal Calibration

- [x] **REFU-01**: Hard block mode: policy-violating requests return a principled refusal
- [x] **REFU-02**: Soft steer mode: borderline requests are rewritten to an allowed formulation when possible
- [x] **REFU-03**: Informative refusal mode: refusal explains why and offers safer adjacent help
- [x] **REFU-04**: Refusal thresholds are tunable from eval data (correct refusal rate, false refusal rate)

### Trace Logging

- [x] **TRAC-01**: Every request/response is logged as a structured JSONL trace with request_id
- [x] **TRAC-02**: Traces include guardrail decisions, CAI critique results, and refusal events
- [x] **TRAC-03**: PII is redacted from traces before writing (compliance-safe)
- [x] **TRAC-04**: Traces are queryable via SQLite for eval and red teaming consumption

### Evals & CI

- [x] **EVAL-01**: Custom replay harness replays curated safety/refusal datasets through POST /chat and scores results
- [x] **EVAL-02**: lm-eval-harness runs capability benchmarks via the gateway (generative) and LiteLLM direct (loglikelihood)
- [x] **EVAL-03**: CI/CD gate blocks promotion if safety metrics regress or over-refusal rate spikes
- [x] **EVAL-04**: Eval results are stored and dashboarded for trend analysis

### Red Teaming

- [x] **RDTM-01**: garak runs one-shot vulnerability scans against the gateway endpoint
- [x] **RDTM-02**: Adversarial prompts are generated from past critiques, evals, and trace logs via deepteam
- [x] **RDTM-03**: Red team jobs run asynchronously via Celery/Redis
- [x] **RDTM-04**: Generated adversarial datasets are balanced to prevent category drift

### HITL Dashboard

- [x] **HITL-01**: Gradio dashboard shows a priority-sorted review queue of flagged requests
- [x] **HITL-02**: Reviewers can see diff-view of original vs critique-revised outputs
- [x] **HITL-03**: Reviewer corrections feed back into threshold calibration and fine-tuning data
- [x] **HITL-04**: Dashboard works headlessly (API-only mode) when no UI is needed

## v1.2 Requirements — Autoresearch Integration

Requirements for the autoresearch end-to-end pipeline milestone. Each maps to roadmap phases.

### Data Integration

- [ ] **DATA-01**: Autoresearch launcher auto-discovers datasets in `~/data/` subdirectories and presents them as data source options
- [ ] **DATA-02**: Autoresearch launcher can use a local HF cache model as the base model for training (auto-detected from `~/.cache/huggingface/hub/`)
- [ ] **DATA-03**: Training data is optionally screened through harness input guardrails (PII, toxicity) before feeding to autoresearch

### Training Safety

- [ ] **TRSF-01**: A post-training hook runs the harness safety replay dataset against each trained checkpoint and logs pass/fail
- [ ] **TRSF-02**: Checkpoints that fail safety eval are flagged with a warning but not deleted (non-destructive)
- [ ] **TRSF-03**: Safety eval results are stored alongside the autoresearch experiment log for review

### Model Registration

- [ ] **MREG-01**: Passing checkpoints are auto-registered in LiteLLM config so they're immediately available for inference behind the harness
- [ ] **MREG-02**: Registered models are servable via vLLM and accessible through the safety harness gateway on :5000
- [ ] **MREG-03**: A deregistration command removes a trained model from LiteLLM config

### Demo & Documentation

- [ ] **DEMO-01**: A runnable demo script executes the full pipeline with a small sample dataset end-to-end
- [ ] **DEMO-02**: Step-by-step documentation walkthrough in README covering data prep → training → safety eval → inference

## v2 Requirements

### Streaming Guardrails

- **STRM-01**: Guardrails evaluate every N tokens during streaming response
- **STRM-02**: Streaming redaction replaces policy-violating content mid-stream
- **STRM-03**: End-of-stream full evaluation catches anything missed during chunked checks

### Advanced Features

- **ADV-01**: Per-model pinning (always keep specific models on hot store)
- **ADV-02**: Scheduled recall (pre-warm models before known usage windows)
- **ADV-03**: Multiple cold tiers (USB drive, NAS mount, etc.)

## Out of Scope

| Feature | Reason |
|---------|--------|
| Cloud storage tiering (S3, GCS) | Local drives only — cloud adds latency and complexity |
| Automatic model downloading | Only manages storage of already-downloaded models |
| RAID or multi-drive pooling | Two-tier only (hot + cold), not a storage pool |
| Fine-tuning orchestration | Harness feeds data for fine-tuning but doesn't run training jobs |
| Model hosting/serving | LiteLLM and vLLM handle that; harness is a safety layer only |
| Web UI for policy editing | Policies are code/config (YAML), not a CMS |
| FUSE filesystem | Over-engineered for the use case; symlinks are simpler and proven |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| INIT-01 | Phase 1 | Complete |
| INIT-02 | Phase 1 | Complete |
| INIT-03 | Phase 1 | Complete |
| INIT-04 | Phase 1 | Complete |
| INIT-05 | Phase 1 | Complete |
| INIT-06 | Phase 1 | Complete |
| INIT-07 | Phase 1 | Complete |
| INIT-08 | Phase 1 | Complete |
| TRCK-01 | Phase 2 | Complete |
| TRCK-02 | Phase 2 | Complete |
| SAFE-01 | Phase 2 | Complete |
| SAFE-02 | Phase 2 | Complete |
| SAFE-06 | Phase 2 | Complete |
| MIGR-01 | Phase 3 | Complete |
| MIGR-02 | Phase 3 | Complete |
| MIGR-03 | Phase 3 | Complete |
| MIGR-04 | Phase 3 | Complete |
| MIGR-05 | Phase 3 | Complete |
| MIGR-06 | Phase 3 | Complete |
| MIGR-07 | Phase 3 | Complete |
| MIGR-08 | Phase 3 | Complete |
| RECL-01 | Phase 3 | Complete |
| RECL-02 | Phase 3 | Complete |
| RECL-03 | Phase 3 | Complete |
| SAFE-03 | Phase 3 | Complete |
| SAFE-04 | Phase 3 | Complete |
| SAFE-05 | Phase 3 | Complete |
| CLI-01 | Phase 4 | Complete |
| CLI-02 | Phase 4 | Complete |
| CLI-03 | Phase 4 | Complete |
| CLI-04 | Phase 4 | Complete |
| CLI-05 | Phase 4 | Complete |
| CLI-06 | Phase 4 | Complete |
| CLI-07 | Phase 4 | Complete |
| DOCS-01 | Phase 4 | Complete |
| DOCS-02 | Phase 4 | Complete |
| DOCS-03 | Phase 4 | Complete |
| DOCS-04 | Phase 4 | Complete |
| GATE-01 | Phase 5 | Complete |
| GATE-02 | Phase 5 | Complete |
| GATE-03 | Phase 5 | Complete |
| GATE-04 | Phase 5 | Complete |
| GATE-05 | Phase 5 | Complete |
| TRAC-01 | Phase 5 | Complete |
| TRAC-02 | Phase 5 | Complete |
| TRAC-03 | Phase 5 | Complete |
| TRAC-04 | Phase 5 | Complete |
| INRL-01 | Phase 6 | Complete |
| INRL-02 | Phase 6 | Complete |
| INRL-03 | Phase 6 | Complete |
| INRL-04 | Phase 6 | Complete |
| INRL-05 | Phase 6 | Complete |
| OURL-01 | Phase 6 | Complete |
| OURL-02 | Phase 6 | Complete |
| OURL-03 | Phase 6 | Complete |
| OURL-04 | Phase 6 | Complete |
| REFU-01 | Phase 6 | Complete |
| REFU-02 | Phase 6 | Complete |
| REFU-03 | Phase 6 | Complete |
| REFU-04 | Phase 6 | Complete |
| CSTL-01 | Phase 7 | Complete |
| CSTL-02 | Phase 7 | Complete |
| CSTL-03 | Phase 7 | Complete |
| CSTL-04 | Phase 7 | Complete |
| CSTL-05 | Phase 7 | Complete |
| EVAL-01 | Phase 8 | Complete |
| EVAL-02 | Phase 8 | Complete |
| EVAL-03 | Phase 8 | Complete |
| EVAL-04 | Phase 8 | Complete |
| RDTM-01 | Phase 9 | Complete |
| RDTM-02 | Phase 9 | Complete |
| RDTM-03 | Phase 9 | Complete |
| RDTM-04 | Phase 9 | Complete |
| HITL-01 | Phase 10 | Complete |
| HITL-02 | Phase 10 | Complete |
| HITL-03 | Phase 10 | Complete |
| HITL-04 | Phase 10 | Complete |
| DATA-01 | Phase 11 | Pending |
| DATA-02 | Phase 11 | Pending |
| DATA-03 | Phase 11 | Pending |
| TRSF-01 | Phase 11 | Pending |
| TRSF-02 | Phase 11 | Pending |
| TRSF-03 | Phase 11 | Pending |
| MREG-01 | Phase 11 | Pending |
| MREG-02 | Phase 11 | Pending |
| MREG-03 | Phase 11 | Pending |
| DEMO-01 | Phase 12 | Pending |
| DEMO-02 | Phase 12 | Pending |

**Coverage:**
- v1.0 requirements: 38 total (38 complete)
- v1.1 requirements: 39 total (39 complete)
- v1.2 requirements: 11 total (0 complete, 11 pending)
- Mapped to phases: 88/88 (100%)
- Unmapped: 0

---
*Requirements defined: 2026-03-21 (v1.0), 2026-03-22 (v1.1), 2026-03-24 (v1.2)*
*Last updated: 2026-03-24 after v1.2 roadmap creation*
