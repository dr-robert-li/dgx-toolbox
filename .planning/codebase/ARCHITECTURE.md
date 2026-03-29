# Architecture

**Analysis Date:** 2026-03-19

## Pattern Overview

**Overall:** Containerized microservice orchestration with shell-script entry points and shared host-mounted directories for data interchange.

**Key Characteristics:**
- Distributed containers (inference servers, toolboxes, labeling platforms) coordinating via host networking and host-gateway DNS
- Data flows through shared host directories (`~/data/*`, `~/eval/*`, `~/triton/*`, etc.) rather than container volumes or APIs
- Unified proxy (LiteLLM) abstracts multiple inference backends (Ollama, vLLM, cloud APIs) into a single OpenAI-compatible endpoint
- Host system setup (Python, build tools, Miniconda, pyenv) bootstrapped once by `dgx-global-base-setup.sh`
- Per-tool bootstrap via build scripts that create Docker images with layered dependencies on NGC PyTorch base

## Layers

**System Layer (Host):**
- Purpose: Foundational environment for development and container execution
- Location: Host OS (DGX Spark aarch64) with setup managed by `dgx-global-base-setup.sh`
- Contains: Python 3, Miniconda (aarch64), pyenv, pyenv-virtualenv, build tools, Docker with NVIDIA Container Toolkit
- Depends on: NVIDIA DGX Spark hardware, NGC container registry access
- Used by: All containers (NGC PyTorch base image) and scripts

**Inference Layer:**
- Purpose: Multiple LLM serving backends with unified proxy routing
- Location: `start-vllm.sh`, `start-ollama-remote.sh`, `start-litellm.sh`, `start-open-webui.sh`
- Contains: Ollama (systemd service at :11434), vLLM (OpenAI-compatible at :8020), LiteLLM proxy (unified at :4000), Open-WebUI (chat UI at :12000)
- Depends on: Host system, NGC PyTorch base, HuggingFace model cache (`~/.cache/huggingface`), model configurations
- Used by: Data toolbox, eval toolbox, n8n, external clients via NVIDIA Sync

**Data Processing Layer:**
- Purpose: Prepare, curate, and generate training data using distributed tools
- Location: `data-toolbox-build.sh` → `data-toolbox.sh`, `data-toolbox-jupyter.sh`
- Contains: pandas, polars, pyarrow, duckdb, datatrove, distilabel, label-studio-sdk, argilla client, cloud storage clients
- Depends on: NGC PyTorch base, host data directories (`~/data/*`)
- Used by: Data engineers, synthetic data generation pipelines

**Evaluation Layer:**
- Purpose: Benchmark models against datasets and compute metrics
- Location: `eval-toolbox-build.sh` → `eval-toolbox.sh`, `eval-toolbox-jupyter.sh`
- Contains: lm-eval, ragas, torchmetrics, evaluate, scikit-learn, mlflow, Triton client, OpenAI client
- Depends on: NGC PyTorch base, host eval directories (`~/eval/*`), LiteLLM proxy for model access
- Used by: ML engineers for benchmarking and evaluation

**Specialized Compute Layer:**
- Purpose: Optimize inference and training for specific use cases
- Location: `triton-trtllm.sh` (TensorRT-LLM), `unsloth-studio.sh` (fine-tuning UI), `ngc-pytorch.sh` (interactive), `ngc-jupyter.sh` (Jupyter)
- Contains: Triton Inference Server with TensorRT-LLM backend, Unsloth Studio, NGC PyTorch environment
- Depends on: NGC PyTorch base, GPU access, model directories
- Used by: Advanced users for fine-tuning, optimization, and custom research

**Orchestration Layer:**
- Purpose: Visual workflow automation and integration between tools
- Location: `start-n8n.sh`
- Contains: n8n workflow engine with OpenAI-compatible node support (via LiteLLM proxy)
- Depends on: LiteLLM proxy, inference backends
- Used by: Non-technical users for no-code ML workflows

**Labeling/Annotation Layer:**
- Purpose: Persistent data annotation services
- Location: `start-label-studio.sh`, `start-argilla.sh`
- Contains: Label Studio (web UI at :8081), Argilla (web UI at :6900) with persistent storage
- Depends on: Host directories, client libraries in data toolbox
- Used by: Data curators via SDKs in data toolbox or web UIs

## Data Flow

**Model Serving Flow:**
1. Host system runs systemd Ollama service (`:11434`)
2. vLLM container pulls models from `~/.cache/huggingface` and serves at `:8020`
3. LiteLLM proxy reads `~/.litellm/config.yaml` and routes requests to Ollama, vLLM, or cloud APIs
4. Open-WebUI connects to LiteLLM (or any backend) and provides chat UI at `:12000`
5. Eval/data toolboxes query LiteLLM via `host.docker.internal:4000` for synthetic generation or evaluation

**Training Data Pipeline:**
1. Raw data ingested to `~/data/raw`
2. Data toolbox reads from `~/data/raw`, processes via pandas/duckdb/polars
3. Intermediate outputs written to `~/data/processed`
4. Quality filtering and deduplication via datatrove writes to `~/data/curated`
5. Synthetic generation via distilabel + LiteLLM writes to `~/data/synthetic`
6. Final exports curated to `~/data/exports` for eval toolbox
7. Eval toolbox reads from `~/data/exports` and `~/eval/models` for training

**Evaluation Flow:**
1. Fine-tuned models checkpointed to `~/eval/models`
2. Eval datasets in `~/eval/datasets`
3. Eval toolbox runs lm-eval/ragas against vLLM or Ollama via LiteLLM proxy
4. Results logged to `~/eval/runs` (mlflow)
5. Triton TRT-LLM can serve optimized engines from `~/triton/engines` for production evaluation

**State Management:**
- Config state: YAML files in `~/.litellm/`, `~/.n8n/`, `~/.vllm-model`, `~/.ollama/`, `~/.open-webui/`
- Data state: Shared host directories (`~/data/*`, `~/eval/*`, `~/triton/*`, `~/.cache/huggingface`)
- Container state: Docker volumes for persistent services (Open-WebUI, Label Studio, Argilla, Unsloth Studio)
- Model state: HuggingFace cache and local model checkpoints
- No in-memory or database state (except within containers during execution)

## Key Abstractions

**Inference Backend (vLLM, Ollama, Cloud APIs):**
- Purpose: Multiple LLM serving options with consistent interface
- Examples: `start-vllm.sh`, `start-litellm.sh`, systemd Ollama service
- Pattern: Each backend exposes OpenAI-compatible API; LiteLLM routes to any

**Toolbox (Data, Eval, NGC):**
- Purpose: Containerized Python environments with pre-installed domain-specific packages
- Examples: `data-toolbox/Dockerfile`, `eval-toolbox/Dockerfile`
- Pattern: Inherit from NGC PyTorch base (includes CUDA/cuDNN), layer domain packages, mount directories from host

**Build-Run Pattern:**
- Purpose: Separate image build from execution for reusability
- Examples: `data-toolbox-build.sh` + `data-toolbox.sh`, `eval-toolbox-build.sh` + `eval-toolbox.sh`
- Pattern: Build script creates image once; launch script runs container with host mounts and GPU access

**Config Generator:**
- Purpose: Detect running services and auto-populate proxy configuration
- Examples: `setup-litellm-config.sh` detects Ollama/vLLM and generates LiteLLM config.yaml
- Pattern: Inspect running containers via Docker API, query service endpoints, prompt for secrets

## Entry Points

**System Bootstrap:**
- Location: `dgx-global-base-setup.sh`
- Triggers: Manual execution once per DGX host
- Responsibilities: Install system packages (apt), Miniconda (aarch64), pyenv, set up PATH

**Container Image Build:**
- Locations: `data-toolbox-build.sh`, `eval-toolbox-build.sh`, `triton-trtllm.sh`, `unsloth-studio.sh`
- Triggers: User-initiated builds (one-time per toolbox)
- Responsibilities: Invoke `docker build` on Dockerfile, tag images, confirm completion

**Container Execution (Interactive):**
- Locations: `data-toolbox.sh`, `eval-toolbox.sh`, `ngc-pytorch.sh`, `ngc-jupyter.sh`, `eval-toolbox-jupyter.sh`, `data-toolbox-jupyter.sh`
- Triggers: User runs script to enter interactive shell
- Responsibilities: Check for running container, reuse if exists, otherwise create with GPU/directory mounts, drop into bash or Jupyter

**Container Execution (Background Service):**
- Locations: `start-vllm.sh`, `start-litellm.sh`, `start-open-webui.sh`, `start-n8n.sh`, `start-label-studio.sh`, `start-argilla.sh`, `triton-trtllm.sh`, `unsloth-studio.sh`
- Triggers: User runs script to start persistent service
- Responsibilities: Create container with `docker run -d`, mount host directories/configs, expose port, stream logs

**Config Generation:**
- Location: `setup-litellm-config.sh`
- Triggers: User-initiated or on first LiteLLM launch
- Responsibilities: Detect Ollama/vLLM running, query their APIs, generate `~/.litellm/config.yaml`, prompt for cloud API keys

**NVIDIA Sync Integration:**
- Locations: All *-sync.sh variants (`start-open-webui-sync.sh`, `start-vllm-sync.sh`, etc.)
- Triggers: Remote execution via `nvidia-sync exec`
- Responsibilities: Same as non-sync versions but detach immediately (background execution)

## Error Handling

**Strategy:** Fail-fast with exit codes; container restart policies (unless-stopped) handle transient failures.

**Patterns:**
- Scripts use `set -e` to exit on first error
- Docker run commands check for existing container before creating (avoid duplicates)
- Fallback Docker run with `||` operator for optional flags (e.g., --env-file in litellm-config)
- Service health checks via HTTP endpoints (`curl -sf`) to detect running services
- Log streaming with `docker logs -f` for debugging (Ctrl+C detaches, container continues)

## Cross-Cutting Concerns

**Logging:**
- Entry point: Each container streams logs to stdout via `docker logs -f`
- Format: Container-native logs (Docker daemon formats timestamps)
- Aggregation: NVIDIA Sync can forward container logs to client machine

**Validation:**
- Config validation: YAML syntax checked by LiteLLM on startup
- Directory validation: Scripts create host directories if missing (`mkdir -p`)
- Service validation: HTTP checks confirm Ollama/vLLM/LiteLLM alive before proceeding

**Authentication:**
- API keys: Stored in plain text in `~/.litellm/.env` (file permissions 600)
- LiteLLM config: YAML with model routing, no embedded secrets
- Cloud API secrets: Environment variables (OPENAI_API_KEY, ANTHROPIC_API_KEY, GEMINI_API_KEY) injected at container startup

**Network:**
- Local: Host networking (localhost:PORT)
- Container-to-host: `--add-host=host.docker.internal:host-gateway` enables containers to reach host services
- Remote: NVIDIA Sync provides port forwarding and remote execution
- DNS: No service discovery; hardcoded endpoints (localhost:8020 for vLLM, etc.)

---

*Architecture analysis: 2026-03-19*
