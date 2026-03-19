# External Integrations

**Analysis Date:** 2026-03-19

## APIs & External Services

**Cloud LLM Providers:**
- OpenAI - GPT-4o, GPT-4o-mini models
  - SDK/Client: `openai` Python package
  - Auth: `OPENAI_API_KEY` env var
  - Used via: LiteLLM proxy at `http://host.docker.internal:4000/v1`

- Anthropic - Claude Sonnet, Claude Haiku models
  - SDK/Client: `openai` SDK (via LiteLLM compatibility layer)
  - Auth: `ANTHROPIC_API_KEY` env var
  - Used via: LiteLLM proxy at `http://host.docker.internal:4000/v1`

- Google Gemini - Gemini 2.5 Pro, Flash, 2.0 Flash models
  - SDK/Client: `openai` SDK (via LiteLLM compatibility layer)
  - Auth: `GEMINI_API_KEY` env var
  - Used via: LiteLLM proxy at `http://host.docker.internal:4000/v1`

**HuggingFace:**
- Model and dataset hub integration
  - SDK/Client: `datasets`, `huggingface_hub` packages
  - Auth: `HUGGING_FACE_HUB_TOKEN` (optional, for private models)
  - Cache location: `~/.cache/huggingface` (mounted across all containers)
  - Purpose: Model downloads, dataset loading, evaluation benchmarks

## Data Storage

**Databases:**
- DuckDB - In-process SQL database
  - Connection: Local files in `/data/` directories
  - Client: `duckdb` Python package + CLI v1.2.2
  - Used for: Fast analytics on curated data

- Argilla - Data annotation database (PostgreSQL-backed, containerized)
  - Connection: Internal to argilla Docker container
  - Client: `argilla` Python SDK
  - Port: 6900

- Label Studio - Data annotation database (SQLite-backed)
  - Connection: Persistent volume at `~/label-studio-data`
  - Client: `label-studio-sdk` Python package
  - Port: 8081

**File Storage:**
- Local filesystem only (no S3 integration at runtime)
- Cloud storage libraries installed but not actively used:
  - `boto3` (AWS S3 / compatible)
  - `azure-storage-blob` (Azure Blob Storage)
  - `google-cloud-storage` (Google Cloud Storage)
  - `smart-open[all]` (Unified cloud I/O interface)
- Host directories mounted into containers:
  - `~/data/raw` → `/data/raw` (raw ingested data)
  - `~/data/processed` → `/data/processed` (cleaned/transformed)
  - `~/data/curated` → `/data/curated` (deduplicated quality-filtered)
  - `~/data/synthetic` → `/data/synthetic` (generated synthetic data)
  - `~/data/exports` → `/data/exports` (final training exports)
  - `~/eval/datasets` → `/datasets` (evaluation datasets)
  - `~/eval/models` → `/models` (fine-tuned checkpoints)
  - `~/.cache/huggingface` → `/root/.cache/huggingface` (HF cache)
  - `~/unsloth-data` → `/workspace/work` (Unsloth fine-tuning data)
  - `~/triton/engines` → `/engines` (Triton compiled models)
  - `~/triton/model_repo` → `/triton_model_repo` (Triton model configs)

**Caching:**
- None configured at runtime
- HuggingFace model cache shared across all containers

## Authentication & Identity

**Auth Provider:**
- Custom: LiteLLM proxy handles all authentication
  - OpenAI, Anthropic, Gemini: API keys stored in `~/.litellm/.env`
  - Ollama, vLLM: No auth (local-only services)
- Label Studio: Built-in user accounts (no LDAP/OAuth)
- Argilla: Built-in user accounts (default: `argilla` / `1234`)
- Open-WebUI: Built-in user accounts (no external auth)
- n8n: Built-in user accounts (no external auth)
- Unsloth Studio: No authentication required

**Implementation:** All cloud API keys managed via `setup-litellm-config.sh` interactive script. Keys stored in `~/.litellm/.env` and loaded into LiteLLM container via `--env-file`.

## Monitoring & Observability

**Error Tracking:**
- None integrated at infrastructure level
- Optional: wandb and mlflow available for experiment tracking

**Logs:**
- Docker logs (via `docker logs -f`)
- LiteLLM: Verbose logging to stdout (setverbose: false in config)
- Triton: HTTP metrics endpoint at `http://localhost:8012/metrics`
- n8n: Built-in execution logs
- Unsloth Studio: Container logs via `docker logs unsloth-studio`

**Experiment Tracking:**
- wandb - Weights & Biases integration (eval toolbox has SDK pre-installed)
- mlflow - MLflow tracking server client (eval toolbox has SDK pre-installed)

## CI/CD & Deployment

**Hosting:**
- Local: NVIDIA DGX Spark (aarch64)
- Remote: NVIDIA Sync for client-side port forwarding and command execution

**CI Pipeline:**
- None built-in; scripts are standalone bash executables
- Deployment model: Manual execution of shell scripts on target machine

**Build/Image Management:**
- Scripts reference stable base images: NGC PyTorch 26.02, Triton 26.02-trtllm
- Image versions for user services pinned:
  - vLLM: `vllm/vllm-openai:latest`
  - LiteLLM: `ghcr.io/berriai/litellm:main-latest`
  - Open-WebUI: `ghcr.io/open-webui/open-webui:ollama`
  - n8n: `n8nio/n8n` (latest)
  - Label Studio: `heartexlabs/label-studio:latest`
  - Argilla: `argilla/argilla-quickstart:latest`
  - Unsloth Studio: `nvcr.io/nvidia/pytorch:25.11-py3` (base image, custom startup)

## Environment Configuration

**Required env vars:**
- `NGC_API_KEY` - For pulling NGC images during setup
- `OPENAI_API_KEY` - (optional, for OpenAI access via LiteLLM)
- `ANTHROPIC_API_KEY` - (optional, for Anthropic access via LiteLLM)
- `GEMINI_API_KEY` - (optional, for Google Gemini access via LiteLLM)
- `HUGGING_FACE_HUB_TOKEN` - (optional, for private HuggingFace model access)

**Secrets location:**
- `~/.litellm/.env` - LiteLLM cloud API keys (created by `setup-litellm-config.sh`)
  - Format: `KEY=value` pairs
  - Loaded into LiteLLM container via `--env-file`
- `~/.n8n/` - n8n encrypted credentials and workflows
- System environment: NGC_API_KEY configured during initial DGX setup

**Docker host.docker.internal:**
- All containers configured with `--add-host=host.docker.internal:host-gateway`
- Enables container-to-host service discovery:
  - `http://host.docker.internal:11434` → Host Ollama
  - `http://host.docker.internal:8020/v1` → Host vLLM
  - `http://host.docker.internal:4000/v1` → Host LiteLLM proxy

## Webhooks & Callbacks

**Incoming:**
- n8n: HTTP endpoints configurable via workflow design
- Label Studio: Webhook export options (not configured by default)
- Argilla: No built-in webhooks

**Outgoing:**
- None configured
- Distilabel: Can call cloud APIs (OpenAI, Anthropic, etc.) via LiteLLM
- wandb/mlflow: Log data to respective platforms if configured

## Service Discovery & Networking

**Inter-service Communication:**
- vLLM, Ollama, LiteLLM listen on `0.0.0.0` (accessible from containers and LAN)
- Containers communicate via `host.docker.internal` hostname
- All services use HTTP (no TLS within local network)
- Shared GPU via `--gpus all` (no multi-tenant isolation)

**Port Registry:**
| Port | Service | Protocol | Purpose |
|------|---------|----------|---------|
| 4000 | LiteLLM Proxy | HTTP | Unified OpenAI-compatible endpoint |
| 5678 | n8n | HTTP | Workflow automation UI |
| 6900 | Argilla | HTTP | Data annotation UI |
| 8000 | Unsloth Studio | HTTP | Fine-tuning UI |
| 8010 | Triton (HTTP) | HTTP | Inference server |
| 8011 | Triton (gRPC) | gRPC | Inference server (binary protocol) |
| 8012 | Triton (metrics) | HTTP | Prometheus metrics |
| 8020 | vLLM | HTTP | OpenAI-compatible inference API |
| 8080 | code-server | HTTP | VS Code in browser (not launched by default) |
| 8081 | Label Studio | HTTP | Data labeling UI |
| 8888 | Jupyter Lab (NGC) | HTTP | Interactive Python (NGC PyTorch base) |
| 8889 | Jupyter Lab (eval) | HTTP | Interactive Python (eval-toolbox) |
| 8890 | Jupyter Lab (data) | HTTP | Interactive Python (data-toolbox) |
| 11434 | Ollama | HTTP | Local LLM API (systemd service) |
| 12000 | Open-WebUI | HTTP | Chat interface with bundled Ollama |

---

*Integration audit: 2026-03-19*
