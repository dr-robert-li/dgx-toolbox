# Technology Stack

**Analysis Date:** 2026-04-01

## Languages

**Primary:**
- Bash - All container launchers, modelstore CLI, infrastructure tooling (~70+ `.sh` files). Scripts use `#!/usr/bin/env bash` with `set -euo pipefail`.
- Python 3.10+ - Safety Harness gateway (`harness/`), eval framework, examples (`examples/dgx_toolbox.py`)

**Secondary:**
- YAML - Docker Compose configs, guardrail/tenant/constitution configs, CI workflows
- SQL - SQLite schema for trace storage (`harness/traces/schema.sql`)

## Runtime

**Environment:**
- Python >=3.10 (CI runs on 3.13 via `actions/setup-python@v5`)
- Docker containers based on `nvcr.io/nvidia/pytorch:26.02-py3` (NVIDIA NGC base, CUDA 12, PyTorch 2.x)
- Target hardware: NVIDIA DGX Spark (128 Blackwell GPU cores, aarch64)
- Ollama runs as systemd service on host (not in Docker)

**Package Manager:**
- pip - Python dependencies inside containers and for harness
- setuptools >=61 as build backend (`harness/pyproject.toml`)
- conda/Miniconda 3 (aarch64) - Optional user-level Python management (`setup/dgx-global-base-setup.sh`)
- uv - Used by karpathy-autoresearch launcher for dependency management (`karpathy-autoresearch/launch-autoresearch.sh`)
- apt-get - System packages in Dockerfiles and setup scripts
- No lockfile committed (no `requirements.lock`, `uv.lock` is gitignored)

## Frameworks

**Core:**
- FastAPI >=0.115 - Safety Harness HTTP gateway (`harness/main.py`)
- uvicorn[standard] >=0.34 - ASGI server (`harness/start-harness.sh`: `uvicorn harness.main:app`)

**AI/ML Safety:**
- NeMo Guardrails >=0.21 - LLM guardrail framework with input/output rails (`harness/guards/engine.py`)
- Presidio Analyzer >=2.2 + Presidio Anonymizer >=2.2 - PII detection and redaction (`harness/pii/redactor.py`)
- spaCy >=3.8.5 - NER model `en_core_web_lg` used by Presidio
- langchain-openai >=0.1 - LLM client for NeMo guardrails (`harness/guards/engine.py`)
- confusable-homoglyphs >=3.2 - Unicode normalization for evasion detection (`harness/guards/normalizer.py`)
- garak >=0.14 - Red team vulnerability scanning (optional `[redteam]` extra)

**Evaluation:**
- lm-eval >=0.4.9 - Standard LLM benchmarks: MMLU, HellaSwag, TruthfulQA, GSM8K (`harness/eval/runner.py`)
- RAGAS - RAG evaluation (eval-toolbox Dockerfile)
- MLflow - Experiment tracking (eval-toolbox Dockerfile)
- evaluate, torchmetrics - Metrics libraries (eval-toolbox)
- tritonclient[all] - Triton inference client (eval-toolbox)

**UI:**
- Gradio >=6.0,<7.0 - HITL review dashboard (`harness/hitl/ui.py`)

**Inference (Docker images, not pip):**
- vLLM (`vllm/vllm-openai:latest`) - GPU inference server, port 8020 (`inference/start-vllm.sh`)
- LiteLLM (`ghcr.io/berriai/litellm:main-latest`) - Unified LLM proxy, port 4000 (`inference/start-litellm.sh`)
- Ollama - Local LLM server (systemd), port 11434
- Open WebUI (`ghcr.io/open-webui/open-webui:ollama`) - Chat UI, port 12000 (`inference/start-open-webui.sh`)
- Triton (`nvcr.io/nvidia/tritonserver:26.02-trtllm-python-py3`) - TensorRT-LLM, port 8010 (`eval/triton-trtllm.sh`)

**Data (Docker images):**
- Label Studio (`heartexlabs/label-studio:latest`) - Data labeling, port 8081 (`data/start-label-studio.sh`)
- Argilla (`argilla/argilla-quickstart:latest`) - Data curation, port 6900 (`data/start-argilla.sh`)

**Training (Docker):**
- Unsloth - Fine-tuning (installed at runtime inside `nvcr.io/nvidia/pytorch:25.11-py3`) (`containers/unsloth-studio.sh`)

**Workflow:**
- n8n (`n8nio/n8n`) - Workflow automation, port 5678 (`containers/start-n8n.sh`)

**Testing:**
- pytest >=8.0 - Test runner
- pytest-asyncio >=0.25 - Async test support (`asyncio_mode = "auto"`)

**Build/Dev:**
- ShellCheck - Shell script linting (CI: `--severity=error`)
- pip-audit - Dependency vulnerability scanning (CI)
- Docker / Docker Compose - Container builds and orchestration

## Key Dependencies

**Critical (Safety Harness):**
- httpx >=0.28 - Async HTTP client for LiteLLM proxy (`harness/proxy/litellm.py`), sync client for HITL UI (`harness/hitl/ui.py`)
- aiosqlite >=0.21 - Async SQLite for trace storage (`harness/traces/store.py`)
- argon2-cffi >=25.1 - API key hashing for tenant auth (`harness/auth/bearer.py`)
- pyyaml >=6.0 - YAML config loading (`harness/config/loader.py`)
- asciichartpy >=1.5 - Terminal chart rendering for eval trends

**Data Stack (data-toolbox Dockerfile):**
- polars, duckdb (v1.2.2 CLI + Python) - Fast data processing
- datatrove[io,processing,cli,s3] - Large-scale data processing
- datasketch, mmh3, xxhash - Probabilistic deduplication and hashing
- ftfy, trafilatura - Text cleaning and web content extraction
- distilabel, Faker - Synthetic data generation
- cleanlab - Data quality detection
- beautifulsoup4, lxml, pdfplumber, python-docx, openpyxl - Document extraction
- label-studio-sdk, argilla - Annotation platform clients
- boto3, azure-storage-blob, google-cloud-storage, smart-open[all] - Multi-cloud I/O
- orjson, msgspec, zstandard - Serialization and compression
- System tools: poppler-utils, tesseract-ocr, pigz, parallel, pv, csvkit

**Base Toolbox (`base-toolbox/Dockerfile`):**
- datasets, pandas, pyarrow, scikit-learn, scipy - Data science essentials
- openai, huggingface_hub - API clients
- typer[all], rich, tqdm - CLI and terminal formatting

## Configuration

**Environment:**
- `HARNESS_PORT` - Safety Harness port (default: 5000)
- `HARNESS_CONFIG_DIR` - Config YAML path (default: `harness/config/`)
- `HARNESS_DATA_DIR` - SQLite traces path (default: `harness/data/`)
- `LITELLM_BASE_URL` - LiteLLM proxy URL (default: `http://localhost:4000`)
- `HARNESS_API_KEY` - Client API key for harness auth
- `VLLM_MODEL` - Model to serve (default: `nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16`)
- `VLLM_GPU_MEM` - GPU memory utilization (default: 0.5)
- `EXTRA_MOUNTS` - Comma-separated extra Docker bind mounts (parsed by `lib.sh:build_extra_mounts`)
- Docker env: `DEBIAN_FRONTEND=noninteractive`, `PIP_NO_CACHE_DIR=1`, `PYTHONUNBUFFERED=1`
- Privacy: `SCARF_NO_ANALYTICS=true`, `DO_NOT_TRACK=true`, `ANONYMIZED_TELEMETRY=false` (Open WebUI)

**Build:**
- `harness/pyproject.toml` - Python package with optional extras: `[test]`, `[eval]`, `[redteam]`
- `build-toolboxes.sh` - Builds base/eval/data Docker images (base -> eval + data)
- `.github/workflows/test.yml` - CI pipeline (shellcheck, pytest, bash syntax, secrets scan, vulnerability scan)

**Base Images:**
- `nvcr.io/nvidia/pytorch:26.02-py3` - Base for eval-toolbox and data-toolbox
- `nvcr.io/nvidia/pytorch:25.11-py3` - Unsloth Studio base
- `nvcr.io/nvidia/tritonserver:26.02-trtllm-python-py3` - Triton TRT-LLM

## Platform Requirements

**Development:**
- Linux (aarch64 preferred for DGX Spark, amd64 supported)
- Docker with NVIDIA Container Toolkit (`--gpus all`)
- Python 3.10+ for harness development
- Bash 4+ for shell scripts
- systemd for Ollama service management
- NGC authentication for pulling base images

**Production:**
- NVIDIA DGX Spark (primary target) or any NVIDIA GPU system
- Docker runtime with NVIDIA Container Toolkit
- NVIDIA Sync for remote access via corporate network
- Persistent host directories: `~/data/`, `~/eval/`, `~/.cache/huggingface/`, `~/unsloth-data/`, `~/.litellm/`

---

*Stack analysis: 2026-04-01*
