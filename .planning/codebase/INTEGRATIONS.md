# External Integrations

**Analysis Date:** 2026-04-01

## APIs & External Services

**LLM Inference (self-hosted):**
- vLLM - OpenAI-compatible API at `http://localhost:8020/v1`
  - Docker image: `vllm/vllm-openai:latest`
  - Launcher: `inference/start-vllm.sh`
  - Model config: `~/.vllm-model` (single line with HuggingFace model ID)
  - HuggingFace cache: `~/.cache/huggingface` mounted at `/root/.cache/huggingface`

- Ollama - Local LLM server at `http://localhost:11434`
  - Runs as systemd service on host (not Docker)
  - Checked via `systemctl is-active ollama` in `status.sh`

- LiteLLM - Unified proxy at `http://localhost:4000`
  - Docker image: `ghcr.io/berriai/litellm:main-latest`
  - Routes to Ollama, vLLM, and optional cloud APIs
  - Config: `~/.litellm/config.yaml` (model routing)
  - API keys: `~/.litellm/.env` (optional, for cloud model routing)
  - Default models: `ollama/llama3.1`, `ollama/gemma3`

- Triton TRT-LLM - Inference at `http://localhost:8010`
  - Scripts: `eval/triton-trtllm.sh`, `eval/triton-trtllm-sync.sh`
  - Client: `tritonclient[all]` (eval-toolbox)
  - Metrics: `http://localhost:8012/metrics`

**Cloud LLM Providers (optional, via LiteLLM):**
- OpenAI - GPT-4o and other models
  - Auth: `OPENAI_API_KEY` in `~/.litellm/.env`
- Anthropic - Claude models
  - Auth: `ANTHROPIC_API_KEY` in `~/.litellm/.env`
- Google Gemini - Gemini models
  - Auth: `GEMINI_API_KEY` in `~/.litellm/.env`
- All accessed via LiteLLM's unified OpenAI-compatible endpoint

**Safety Harness Gateway:**
- FastAPI gateway at `http://localhost:5000` (configurable via `HARNESS_PORT`)
  - Proxies `/v1/chat/completions` to LiteLLM
  - Pipeline: auth -> rate limit -> unicode normalize -> input guardrails -> proxy -> output guardrails -> CAI critique -> PII redact -> trace write
  - Launcher: `harness/start-harness.sh`
  - Entry: `harness/main.py` (FastAPI app with lifespan)
  - Main proxy: `harness/proxy/litellm.py`

**NeMo Guardrails:**
- NVIDIA NeMo LLMRails for input/output safety rails
  - SDK: `nemoguardrails>=0.21`
  - Config: `harness/config/rails/` (rails.yaml, config.yml)
  - Uses LiteLLM-backed LLM via `langchain_openai.ChatOpenAI` (`harness/guards/engine.py`)
  - Input rails: `self_check_input`, `jailbreak_detection`, `sensitive_data_input`, `injection_heuristic`
  - Output rails: `self_check_output`, `jailbreak_output`, `sensitive_data_output`
  - Three refusal modes: `hard_block`, `soft_steer`, `informative`
  - Gracefully degrades to regex-only mode when NeMo unavailable

**HuggingFace Hub:**
- Model downloads via `huggingface_hub` and `huggingface-cli`
  - Cache: `~/.cache/huggingface/hub/`
  - Auth: `HUGGING_FACE_HUB_TOKEN` (optional, for private models)
  - Used in autoresearch launcher for model selection

**Kaggle API:**
- Dataset downloads via `kaggle` CLI
  - Config: `~/.kaggle/kaggle.json`
  - Used in autoresearch data source selection (`karpathy-autoresearch/launch-autoresearch.sh`)
  - Setup: `setup/dgx-global-base-setup.sh`

**karpathy/autoresearch:**
- External repo cloned at `~/autoresearch/`
  - Launcher: `karpathy-autoresearch/launch-autoresearch.sh`
  - DGX Spark tuning: `karpathy-autoresearch/spark-config.sh`
  - Data sources: built-in, local, HuggingFace, GitHub, Kaggle
  - Uses `uv` for dependency management

## Data Storage

**Databases:**
- SQLite (via aiosqlite, WAL mode) - Safety Harness trace storage
  - Location: `harness/data/traces.db`
  - Schema: `harness/traces/schema.sql`
  - Tables: `traces`, `eval_runs`, `redteam_jobs`, `corrections`
  - Client: `harness/traces/store.py` (async `TraceStore` class)
  - All PII redacted before storage

- DuckDB - Data processing and analytics
  - CLI: v1.2.2 (installed in `data-toolbox/Dockerfile`)
  - Python: `duckdb` package (data-toolbox)

- Label Studio - Annotation database (SQLite-backed, containerized)
  - Persistent volume: `~/label-studio-data`
  - Client: `label-studio-sdk` Python package
  - Port: 8081

- Argilla - Annotation database (containerized)
  - Client: `argilla` Python package
  - Port: 6900

**File Storage:**
- Local filesystem only (no cloud storage in core toolbox)
- Host directories mounted into containers:
  - `~/data/` - Training and raw datasets
  - `~/eval/models/` - Model checkpoints (mounted at `/models` in vLLM)
  - `~/unsloth-data/` - Unsloth training workspace
  - `~/label-studio-data/` - Label Studio data
  - `~/.n8n/` - n8n workflow persistence
  - `~/.cache/huggingface/` - Model weights and tokenizers
- Docker volumes: `open-webui`, `open-webui-ollama` (external, declared in `docker-compose.inference.yml`)

**Cloud Storage Clients (data-toolbox only, not used by core):**
- `boto3` - AWS S3
- `azure-storage-blob` - Azure Blob Storage
- `google-cloud-storage` - GCS
- `smart-open[all]` - Unified cloud I/O

**Caching:**
- HuggingFace cache at `~/.cache/huggingface/` shared across all containers
- In-memory sliding window rate limiter (`harness/ratelimit/sliding_window.py`)
- No Redis or Memcached

## Authentication & Authorization

**Safety Harness Tenant Auth:**
- Bearer token authentication (`harness/auth/bearer.py`)
- API keys hashed with Argon2id (`argon2-cffi>=25.1`)
- Tenant config: `harness/config/tenants.yaml`
  - Per-tenant fields: `api_key_hash`, `rpm_limit`, `tpm_limit`, `allowed_models`, `bypass`, `pii_strictness`, `rail_overrides`
  - Example tenants: `dev-team` (full guardrails, balanced PII), `ci-runner` (bypass mode, minimal PII)
- Rate limiting: In-memory sliding window per-tenant (RPM + TPM)
  - Implementation: `harness/ratelimit/sliding_window.py`

**LiteLLM Auth:**
- Cloud API keys stored in `~/.litellm/.env`
- Loaded via Docker `--env-file` flag

**Other Services:**
- Label Studio, Argilla, Open WebUI, n8n: Built-in user accounts (no external identity provider)
- Unsloth Studio: No authentication
- vLLM, Ollama: No auth (local-only)

## Monitoring & Observability

**Error Tracking:**
- None (no Sentry, Datadog, or similar)

**Logging:**
- Python `logging` module: `logging.getLogger("harness.proxy")` in `harness/proxy/litellm.py`
- Docker container logs: All services stream via `docker logs -f`
- Modelstore audit log: `modelstore/lib/audit.sh`
- LiteLLM: `set_verbose: false` in config

**Tracing:**
- Custom SQLite-based trace store (`harness/traces/store.py`)
  - Every proxied request recorded: tenant, model, redacted prompt/response, latency_ms, guardrail decisions, CAI critique, refusal events
  - PII redacted before any SQLite write (never persists raw PII)
  - HITL review queue with priority scoring (`compute_priority` in `harness/traces/store.py`)

**Metrics/Dashboards:**
- Gradio HITL dashboard (`harness/hitl/ui.py`): Review queue with filtering by rail/tenant/time, approve/reject/edit corrections, side-by-side diff view
- MLflow: Experiment tracking (eval-toolbox, local file store)
- Eval metrics: F1, precision, recall, correct/false refusal rates, P50/P95 latency (`harness/eval/metrics.py`)
- Eval trend tracking with baseline comparison (`harness/eval/trends.py`)
- Triton: Prometheus metrics at `http://localhost:8012/metrics`

**Health Checks:**
- `status.sh` - Checks all Docker containers and systemd services, reports disk usage
- No formal healthcheck endpoints in FastAPI app

## CI/CD & DevOps

**Hosting:**
- Self-hosted on NVIDIA DGX Spark hardware
- No cloud deployment target
- Remote access via NVIDIA Sync

**CI Pipeline (`.github/workflows/test.yml`):**
- **shellcheck** - Lint all `.sh` files with `--severity=error` (excludes `karpathy-autoresearch/`)
- **harness-tests** - `pytest harness/tests/ -x -q` on Python 3.13
- **bash-syntax** - `bash -n` parse check on all scripts
- **secrets-scan** - Regex scan for leaked API keys (Kaggle `KGAT_`, Anthropic `sk-ant-`, OpenAI `sk-proj-`, Google `AIza`, GitHub `ghp_`/`gho_`, AWS `AKIA`, HuggingFace `hf_`)
- **vulnerability-scan** - `pip-audit` for fixable dependency vulnerabilities
- Triggered on push/PR to `main`

**Deployment Automation:**
- `build-toolboxes.sh` - Builds Docker images: base-toolbox -> eval-toolbox + data-toolbox
- `setup/dgx-global-base-setup.sh` - Idempotent system setup: apt packages, Miniconda, pyenv, harness install, spaCy model, bash aliases
- Docker Compose files:
  - `docker-compose.inference.yml` - Open WebUI + LiteLLM + vLLM (vLLM in `with-vllm` profile)
  - `docker-compose.data.yml` - Label Studio + Argilla
- Individual launcher scripts with sync variants (`*-sync.sh`) for headless operation

## Webhooks & Callbacks

**Incoming (Safety Harness API routes):**
- `POST /v1/chat/completions` - Main proxy endpoint (`harness/proxy/litellm.py`)
- `POST /probe` - Auth verification (`harness/main.py`)
- Admin endpoints via `harness/proxy/admin.py`
- Red team endpoints via `harness/redteam/router.py`
- HITL endpoints via `harness/hitl/router.py`

**Outgoing:**
- Safety Harness -> LiteLLM at `LITELLM_BASE_URL` (httpx async client, 120s timeout, 50 max connections)
- NeMo guardrails -> LiteLLM for rail evaluation via `LLMRails`
- CAI critique engine -> LiteLLM for constitutional AI revision loops (`harness/critique/engine.py`)
- garak -> Safety Harness gateway for red team probing (`harness/redteam/garak_runner.py`)

**Cron/Scheduled:**
- Modelstore migration cron: `modelstore/cron/migrate_cron.sh`
- Modelstore disk check cron: `modelstore/cron/disk_check_cron.sh`

## Environment Configuration

**Required env vars for Safety Harness:**
- `HARNESS_API_KEY` - Client API key (set in `~/.bashrc` by setup script, default: `sk-devteam-test`)

**Optional env vars:**
- `HARNESS_PORT` - Gateway port (default: 5000)
- `HARNESS_CONFIG_DIR` - Config directory path
- `HARNESS_DATA_DIR` - Data/traces directory path
- `LITELLM_BASE_URL` - LiteLLM backend URL (default: `http://localhost:4000`)
- `VLLM_MODEL` - Model for vLLM to serve
- `VLLM_GPU_MEM` - GPU memory fraction for vLLM (default: 0.5)
- `EXTRA_MOUNTS` - Additional Docker bind mounts (comma-separated `host:container` pairs)
- `AUTORESEARCH_BASE_MODEL` - HF model snapshot path for autoresearch
- `AUTORESEARCH_HF_DATASET` - HF dataset identifier for autoresearch
- `NGC_API_KEY` - For pulling NGC images during setup

**Secrets location:**
- `~/.litellm/.env` - LiteLLM cloud API keys (optional)
- `~/.kaggle/kaggle.json` - Kaggle API credentials
- `harness/config/tenants.yaml` - Argon2id-hashed API keys (safe to commit, hashes only)
- All `.env` files are gitignored

## Service Discovery & Networking

**Inter-service Communication:**
- Containers use `host.docker.internal` (via `--add-host=host.docker.internal:host-gateway`)
- All services bind to `0.0.0.0` (accessible from containers and LAN)
- All HTTP, no TLS within local network
- Shared GPU via `--gpus all`, `--ipc=host`

**Port Registry:**
| Port | Service | Launcher |
|------|---------|----------|
| 4000 | LiteLLM Proxy | `inference/start-litellm.sh` |
| 5000 | Safety Harness | `harness/start-harness.sh` |
| 5678 | n8n | `containers/start-n8n.sh` |
| 6900 | Argilla | `data/start-argilla.sh` |
| 8000 | Unsloth Studio | `containers/unsloth-studio.sh` |
| 8010 | Triton HTTP | `eval/triton-trtllm.sh` |
| 8020 | vLLM | `inference/start-vllm.sh` |
| 8081 | Label Studio | `data/start-label-studio.sh` |
| 11434 | Ollama | systemd service |
| 12000 | Open WebUI | `inference/start-open-webui.sh` |

---

*Integration audit: 2026-04-01*
