# Architecture

**Analysis Date:** 2026-04-01

## Pattern Overview

**Overall:** Monorepo of loosely-coupled subsystems orchestrated via shell scripts and Docker containers, with one embedded Python microservice (Safety Harness).

**Key Characteristics:**
- Shell-script-first launcher pattern: each service is a standalone bash script that manages its own Docker container lifecycle
- Shared library (`lib.sh`) provides common container management primitives
- The Safety Harness is the only subsystem with a true application architecture (FastAPI, layered Python modules)
- No inter-service communication bus; services connect point-to-point (e.g., Harness proxies to LiteLLM, LiteLLM routes to vLLM/Ollama)
- Configuration is file-based (YAML, JSON) with no centralized config service
- Docker image hierarchy: `base-toolbox` (NGC PyTorch) -> `eval-toolbox` + `data-toolbox`

## Layers

**Infrastructure Layer (Shell Scripts):**
- Purpose: Container lifecycle management, service orchestration, system setup
- Location: `lib.sh`, `status.sh`, `build-toolboxes.sh`, `setup/dgx-global-base-setup.sh`
- Contains: Docker run/stop/status commands, shared helper functions, system provisioning
- Depends on: Docker, systemd (for Ollama)
- Used by: All launcher scripts, bash aliases
- Key functions in `lib.sh`: `is_running()`, `ensure_container()`, `print_banner()`, `stream_logs()`, `sync_exit()`, `build_extra_mounts()`

**Inference Layer:**
- Purpose: Serve LLM models via OpenAI-compatible APIs
- Location: `inference/`, `docker-compose.inference.yml`
- Contains: Launcher scripts for vLLM, LiteLLM, Open-WebUI, Ollama remote setup
- Depends on: Docker, NVIDIA GPU drivers, HuggingFace model cache
- Used by: Safety Harness (proxies through LiteLLM), end users (via Open-WebUI or API)
- Key services:
  - **Ollama** (systemd, port 11434) -- host-native inference
  - **vLLM** (`inference/start-vllm.sh`, port 8020) -- high-throughput GPU inference
  - **LiteLLM** (`inference/start-litellm.sh`, port 4000) -- unified API proxy routing to all backends
  - **Open-WebUI** (`inference/start-open-webui.sh`, port 12000) -- chat UI

**Safety Harness Layer (Python/FastAPI):**
- Purpose: API gateway with auth, rate limiting, guardrails, PII redaction, Constitutional AI critique, tracing
- Location: `harness/`
- Contains: FastAPI app, proxy routes, guardrail engine, PII redactor, trace store, eval framework, red team engine, HITL review system
- Depends on: LiteLLM (upstream), SQLite (traces), NeMo Guardrails (optional), spaCy (PII)
- Used by: API consumers who need safety-wrapped LLM access
- Entry point: `harness/main.py` via `harness/start-harness.sh` (uvicorn, port 5000)

**Fine-Tuning Layer:**
- Purpose: Model fine-tuning via Unsloth
- Location: `containers/unsloth-studio.sh`, `containers/unsloth-headless.sh`, `containers/unsloth-headless-sync.sh`
- Contains: Container launchers for interactive (Studio UI, port 8000) and headless training
- Depends on: NVIDIA PyTorch container (nvcr.io), GPU, HuggingFace cache

**Data Engineering Layer:**
- Purpose: Data processing, labeling, curation for ML pipelines
- Location: `data/`, `data-toolbox/Dockerfile`, `docker-compose.data.yml`
- Contains: Toolbox container (polars, DuckDB, datatrove, etc.), Label Studio (port 8081), Argilla (port 6900) launchers
- Depends on: base-toolbox image, Docker

**Evaluation Layer:**
- Purpose: Model benchmarking and evaluation
- Location: `eval/`, `eval-toolbox/Dockerfile`, `harness/eval/`
- Contains: Toolbox container (lm-eval, RAGAS, MLflow), Triton TRT-LLM server (port 8010), eval gate/replay/trends within Harness
- Depends on: base-toolbox image, Docker, LiteLLM/Harness for API-based evals

**Model Store Layer:**
- Purpose: Tiered model storage management (hot NVMe <-> cold HDD/NAS)
- Location: `modelstore/`, `modelstore.sh`
- Contains: CLI router, subcommands (init, status, migrate, recall, revert), adapter libraries for HF and Ollama
- Depends on: jq, mount points, cron (for automated migration)
- Architecture: CLI router pattern -- `modelstore.sh` dispatches to `modelstore/cmd/*.sh`, shared logic in `modelstore/lib/*.sh`

**Autoresearch Layer:**
- Purpose: Karpathy autoresearch integration for autonomous ML experimentation
- Location: `karpathy-autoresearch/`
- Contains: Interactive launcher with data source selection, DGX Spark GPU tuning, HF model selection
- Depends on: uv (Python package manager), autoresearch repo (cloned at runtime)

**Container Images Layer:**
- Purpose: Pre-built Docker images with ML tooling
- Location: `base-toolbox/Dockerfile`, `eval-toolbox/Dockerfile`, `data-toolbox/Dockerfile`
- Build hierarchy: `base-toolbox` (NGC PyTorch 26.02) -> `eval-toolbox` + `data-toolbox`
- Built via: `build-toolboxes.sh`

**Programmatic Interface:**
- Purpose: Python execution engine for container-based ML pipelines
- Location: `examples/dgx_toolbox.py`
- Contains: `DGXToolbox` class with validation, container lifecycle, execution engine, status reporting
- Pattern: Singleton with config-driven component resolution and idempotent execution

## Data Flow

**LLM Request Flow (through Safety Harness):**

1. Client sends `POST /v1/chat/completions` with Bearer token to Harness (`:5000`)
2. `harness/auth/bearer.py` verifies API key against Argon2 hashes in tenant config
3. `harness/ratelimit/sliding_window.py` checks RPM and TPM limits (sliding window, in-memory)
4. `harness/guards/normalizer.py` normalizes Unicode (detects evasion attempts)
5. `harness/guards/engine.py` runs all enabled input rails (injection regex, PII, NeMo) -- run-all, not fail-fast
6. If blocked: return refusal (hard_block), rewrite and forward (soft_steer), or explain (informative)
7. Proxy request to LiteLLM at `localhost:4000` via httpx.AsyncClient
8. Run output rails on response (self_check_output, jailbreak_output, sensitive_data_output)
9. If borderline (score >= critique_threshold but not blocked): `harness/critique/engine.py` runs Constitutional AI critique-revise loop via judge model
10. Background task: PII-redact prompt+response via spaCy NER, write trace to SQLite (`harness/traces/store.py`)

**Model Migration Flow (ModelStore):**

1. `modelstore.sh migrate` loads config from `~/.modelstore/config.json`
2. Scans `usage.json` for models past `retention_days`
3. For each stale model: write op_state (interrupt safety), rsync to cold path, create symlink, audit log
4. Supports both HuggingFace cache (`modelstore/lib/hf_adapter.sh`) and Ollama models (`modelstore/lib/ollama_adapter.sh`)
5. Automated via cron (`modelstore/cron/migrate_cron.sh`) or manual invocation

**Autoresearch Flow:**

1. `karpathy-autoresearch/launch-autoresearch.sh` clones/pulls karpathy/autoresearch
2. User selects data source (default, local dir, HF dataset, GitHub repo, Kaggle dataset, auto-discovered ~/data/ subdirs)
3. Runs `prepare.py` to tokenize data
4. Applies DGX Spark GPU tuning via `karpathy-autoresearch/spark-config.sh`
5. Optionally selects base model from HF cache
6. Points AI agent at `program.md` for autonomous experiment loop

**Red Team Flow:**

1. `POST /admin/redteam/start` dispatches red team job via `harness/redteam/router.py`
2. Job types: `garak` (external tool, `harness/redteam/garak_runner.py`) or `deepteam` (internal, `harness/redteam/engine.py`)
3. Deepteam: queries near-miss traces, generates adversarial variants via judge model, writes to pending JSONL (`harness/eval/datasets/pending/`)
4. Balance scoring in `harness/redteam/balance.py` prevents imbalanced test suites

**State Management:**
- Harness state: SQLite database at `harness/data/traces.db` (tables: traces, eval_runs, redteam_jobs, corrections)
- ModelStore state: JSON files at `~/.modelstore/` (config.json, usage.json, op_state.json, audit.jsonl)
- LiteLLM config: YAML at `~/.litellm/config.yaml`
- Container state: Docker daemon (no custom state files)
- Rate limiter: In-memory sliding window (resets on Harness restart)

## Key Abstractions

**TenantConfig (`harness/config/loader.py`):**
- Purpose: Per-tenant API configuration (rate limits, allowed models, PII strictness, guardrail overrides)
- Pattern: Pydantic model loaded from `tenants.yaml`
- Fields: `tenant_id`, `api_key_hash`, `rpm_limit`, `tpm_limit`, `allowed_models`, `bypass`, `pii_strictness`, `rail_overrides`

**GuardrailEngine (`harness/guards/engine.py`):**
- Purpose: Central guardrail execution with run-all-rails aggregation
- Pattern: Engine with pluggable rails (regex + NeMo), three refusal modes (hard_block, soft_steer, informative)
- Input rails: `self_check_input`, `jailbreak_detection`, `sensitive_data_input`, `injection_heuristic`
- Output rails: `self_check_output`, `jailbreak_output`, `sensitive_data_output`
- Fail-open: NeMo unavailability defaults to pass (score=0.0)

**CritiqueEngine (`harness/critique/engine.py`):**
- Purpose: Constitutional AI single-pass critique-revise loop for borderline outputs
- Pattern: Risk-gated (only runs when score >= critique_threshold but < threshold), judge model call with category-filtered principles
- Fail-open: timeout or parse failure returns None

**TraceStore (`harness/traces/store.py`):**
- Purpose: Async SQLite storage for request traces, eval runs, red team jobs, and HITL corrections
- Pattern: Repository with typed write/query methods, WAL mode for concurrent access
- Tables: `traces`, `eval_runs`, `redteam_jobs`, `corrections`

**RailConfig (`harness/config/rail_loader.py`):**
- Purpose: Per-rail configuration (enabled, threshold, refusal_mode, critique_threshold)
- Pattern: Loaded from `rails.yaml`

**DGXToolbox (`examples/dgx_toolbox.py`):**
- Purpose: Programmatic interface for container-based pipeline execution
- Pattern: Singleton execution engine with validation checks, container lifecycle, idempotent execution, status reporting

**lib.sh Functions (`lib.sh`):**
- Purpose: Container lifecycle primitives shared across all launcher scripts
- Key functions: `is_running()`, `container_exists()`, `ensure_container()`, `print_banner()`, `stream_logs()`, `sync_exit()`, `build_extra_mounts()`

## Entry Points

**Shell Script Launchers (user-facing):**
- `inference/start-vllm.sh` -- Start vLLM inference server (port 8020)
- `inference/start-litellm.sh` -- Start LiteLLM API proxy (port 4000)
- `inference/start-open-webui.sh` -- Start Open-WebUI chat interface (port 12000)
- `inference/setup-litellm-config.sh` -- Auto-generate LiteLLM config
- `inference/setup-ollama-remote.sh` -- Enable Ollama LAN access
- `containers/unsloth-studio.sh` -- Start Unsloth fine-tuning UI (port 8000)
- `containers/unsloth-headless.sh` -- Start headless training container
- `containers/ngc-pytorch.sh` -- Interactive PyTorch shell
- `containers/ngc-jupyter.sh` -- Jupyter Lab on NGC PyTorch (port 8888)
- `containers/start-n8n.sh` -- n8n workflow automation (port 5678)
- `harness/start-harness.sh` -- Start Safety Harness gateway (port 5000)
- `data/start-label-studio.sh` -- Start Label Studio (port 8081)
- `data/start-argilla.sh` -- Start Argilla (port 6900)
- `data/data-toolbox.sh` -- Interactive data processing shell
- `data/data-toolbox-jupyter.sh` -- Jupyter Lab with data stack (port 8890)
- `eval/eval-toolbox.sh` -- Interactive eval shell
- `eval/eval-toolbox-jupyter.sh` -- Jupyter Lab with eval stack (port 8889)
- `eval/triton-trtllm.sh` -- Triton + TRT-LLM server (port 8010)
- `karpathy-autoresearch/launch-autoresearch.sh` -- Launch autoresearch agent
- `modelstore.sh` -- Model store CLI (dispatches to `modelstore/cmd/*.sh`)
- `status.sh` -- Show all service statuses
- `build-toolboxes.sh` -- Build Docker images

**Sync Variants:**
- Many launchers have `-sync.sh` variants (e.g., `inference/start-vllm-sync.sh`) that print status and exit immediately without streaming logs, designed for NVIDIA Sync remote sessions

**FastAPI Routes (Harness):**
- `POST /v1/chat/completions` -- Main proxy endpoint (`harness/proxy/litellm.py`)
- `POST /probe` -- Auth test endpoint (`harness/main.py`)
- `POST /admin/suggest-tuning` -- Tuning analysis (`harness/proxy/admin.py`)
- `POST /admin/redteam/start` -- Red team job dispatch (`harness/redteam/router.py`)
- `GET /admin/redteam/status/{job_id}` -- Red team job status (`harness/redteam/router.py`)
- `GET /admin/hitl/queue` -- HITL review queue (`harness/hitl/router.py`)
- `POST /admin/hitl/correct` -- Submit correction (`harness/hitl/router.py`)

**Docker Compose:**
- `docker-compose.inference.yml` -- Inference stack (Open-WebUI + LiteLLM + vLLM)
- `docker-compose.data.yml` -- Data stack (Label Studio + Argilla)

**Bash Aliases:**
- `example.bash_aliases` -- User-friendly command aliases for all services (68 aliases)

**CI/CD:**
- `.github/workflows/test.yml` -- ShellCheck, harness pytest, bash syntax, secrets scan, vulnerability scan

## Error Handling

**Strategy:** Fail-open for safety subsystems, fail-fast for infrastructure

**Patterns:**
- Harness guardrails: NeMo failures default to pass (score=0.0) -- fail-open to avoid blocking legitimate requests
- Harness critique: Timeout (60s) and parse failures return None -- fail-open
- Harness auth: 401 on invalid API key, iterates all tenants with Argon2 verify
- ModelStore: Operation state files (`op_state.json`) provide interrupt safety -- stale state cleared after 4 hours
- ModelStore: Space checks with 10% safety margin before migration (`check_space()` in `modelstore/lib/common.sh`)
- ModelStore: Filesystem validation rejects exfat/vfat/ntfs, warns on unknown fs (`validate_cold_fs()`)
- Shell scripts: `set -e` / `set -euo pipefail` for fail-fast behavior
- Container launchers: Check if already running before starting (idempotent)
- Docker containers: `--restart unless-stopped` for automatic recovery

## Cross-Cutting Concerns

**Logging:**
- Harness: Python `logging` module with `harness.proxy` logger
- Shell scripts: `echo` to stdout/stderr, ModelStore uses `ms_log()` and `ms_die()` prefixed helpers in `modelstore/lib/common.sh`
- Container logs: `docker logs -f` for real-time streaming
- Audit: ModelStore writes structured audit records to `~/.modelstore/audit.jsonl` via `modelstore/lib/audit.sh`

**Validation:**
- Harness: Pydantic models for tenant config (`harness/config/loader.py`), FastAPI request validation
- ModelStore: Filesystem validation (`validate_cold_fs`), mount verification (`check_cold_mounted`), space checks
- DGXToolbox: Pluggable validation engine with named checks (toolbox, memory, container, mounted, gpu, deps) in `examples/dgx_toolbox.py`

**Authentication:**
- Harness: HTTPBearer with Argon2 password hashing (`harness/auth/bearer.py`)
- LiteLLM: Optional env-based API keys via `~/.litellm/.env`
- Other services: No authentication (local network assumption)

**PII Protection:**
- Harness traces: All prompts and responses PII-redacted before SQLite write (`harness/pii/redactor.py`)
- Redaction engine: spaCy NER (`en_core_web_lg`) with configurable strictness levels
- HITL corrections: Edited responses also PII-redacted before storage
- Input/output rails: `sensitive_data_input` and `sensitive_data_output` detect PII in real-time

---

*Architecture analysis: 2026-04-01*
