# DGX Toolbox

Battle-tested scripts for spinning up ML/AI tools on the **NVIDIA DGX Spark**, designed for both local use and remote access via [NVIDIA Sync](https://docs.nvidia.com/dgx/dgx-spark/nvidia-sync.html#spark-nvidia-sync).

## Prerequisites

- NVIDIA DGX Spark (aarch64)
- Docker with NVIDIA Container Toolkit (`--gpus all` support)
- NGC container registry access (`nvcr.io`)
- For remote use: [NVIDIA Sync](https://docs.nvidia.com/dgx/dgx-spark/nvidia-sync.html#spark-nvidia-sync) configured on your client machine

## Quick Start

```bash
# Clone to your DGX
git clone <repo-url> ~/dgx-toolbox

# One-time system setup (Python, Miniconda, pyenv)
bash ~/dgx-toolbox/dgx-global-base-setup.sh
source ~/.bashrc

# Build toolbox images (one-time each)
bash ~/dgx-toolbox/eval-toolbox-build.sh
bash ~/dgx-toolbox/data-toolbox-build.sh

# Enable Ollama for remote/LAN access
bash ~/dgx-toolbox/setup-ollama-remote.sh
```

## Scripts

### System Setup

| Script | Purpose |
|--------|---------|
| `dgx-global-base-setup.sh` | Idempotent system init — installs build tools, Miniconda (aarch64), and pyenv |
| `setup-ollama-remote.sh` | Reconfigure Ollama to listen on all interfaces for Sync/LAN access (requires sudo) |

### Inference Playground

Tools for serving models and interacting with them — chat, code, agentic workflows. Covers both web UIs for non-technical users and CLI/API access for technical users.

#### Open-WebUI (Chat Interface)

| Script | Purpose | Port |
|--------|---------|------|
| `start-open-webui.sh` | Open-WebUI with bundled Ollama — streams logs | 12000 |
| `start-open-webui-sync.sh` | NVIDIA Sync variant — returns immediately | 12000 |

Full-featured chat interface with RAG, image generation, multi-model support, and conversation history. Uses the `ghcr.io/open-webui/open-webui:ollama` image with bundled Ollama. Data persisted in Docker volumes `open-webui` and `open-webui-ollama`.

```bash
open-webui          # http://localhost:12000
open-webui-stop
```

#### vLLM (High-Throughput Inference Server)

| Script | Purpose | Port |
|--------|---------|------|
| `start-vllm.sh` | vLLM OpenAI-compatible server — streams logs | 8020 |
| `start-vllm-sync.sh` | NVIDIA Sync variant — returns immediately | 8020 |

OpenAI-compatible API server optimized for high-throughput batched inference. Faster than Ollama for production workloads and batch evaluation. Requires a model name argument.

```bash
# Serve a HuggingFace model
vllm meta-llama/Llama-3.1-8B-Instruct

# Serve a local fine-tuned model from ~/eval/models/
vllm /models/my-finetuned-model

# With extra args
vllm unsloth/Llama-3.1-8B-Instruct --max-model-len 4096

# Query the API
curl http://localhost:8020/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "meta-llama/Llama-3.1-8B-Instruct", "messages": [{"role": "user", "content": "Hello"}]}'

# Stop
vllm-stop
```

HuggingFace cache (`~/.cache/huggingface`) and model checkpoints (`~/eval/models`) are mounted automatically.

#### LiteLLM (Unified API Proxy)

| Script | Purpose | Port |
|--------|---------|------|
| `start-litellm.sh` | LiteLLM proxy — streams logs | 4000 |
| `start-litellm-sync.sh` | NVIDIA Sync variant — returns immediately | 4000 |

Unified OpenAI-compatible proxy that routes to Ollama, vLLM, and cloud APIs (OpenAI, Anthropic, etc.) through a single endpoint. All tools — Open-WebUI, Aider, n8n, custom code — can point to `localhost:4000` and access any backend.

```bash
litellm             # http://localhost:4000
litellm-stop
```

Configuration lives in `~/.litellm/config.yaml`. On first run, a default config is created with Ollama models. Edit it to add vLLM endpoints and cloud API keys:

```yaml
model_list:
  - model_name: llama3.1
    litellm_params:
      model: ollama/llama3.1
      api_base: http://host.docker.internal:11434
  - model_name: vllm-model
    litellm_params:
      model: openai/your-model-name
      api_base: http://host.docker.internal:8020/v1
      api_key: "none"
  - model_name: claude-sonnet
    litellm_params:
      model: anthropic/claude-sonnet-4-20250514
```

For cloud API keys, create `~/.litellm/.env`:

```bash
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
```

#### Ollama (Local LLM Server)

Ollama runs as a systemd service (pre-installed on DGX Spark). By default it listens on `localhost:11434` only.

```bash
# Enable remote/LAN access (one-time, requires sudo)
ollama-remote

# Pull and run models
ollama pull llama3.1
ollama run llama3.1

# API access
curl http://localhost:11434/api/generate -d '{"model": "llama3.1", "prompt": "Hello"}'
```

#### Inference Architecture

```
                    ┌─────────────────┐
                    │   Open-WebUI     │ :12000  (chat UI)
                    └────────┬────────┘
                             │
    ┌────────────────────────┼────────────────────────┐
    │                        │                         │
    ▼                        ▼                         ▼
┌────────┐           ┌────────────┐            ┌────────────┐
│ Ollama │ :11434    │  LiteLLM   │ :4000      │   vLLM     │ :8020
│ (local │           │  (proxy)   │            │ (OpenAI    │
│  LLMs) │           │            │            │  compat)   │
└────────┘           └─────┬──────┘            └────────────┘
                           │
              routes to any backend:
              Ollama, vLLM, OpenAI,
              Anthropic, etc.
```

### GPU Containers

| Script | Purpose | Port |
|--------|---------|------|
| `ngc-pytorch.sh` | Interactive PyTorch shell with GPU access | — |
| `ngc-jupyter.sh` | Jupyter Lab on NGC PyTorch container | 8888 |
| `ngc-quickstart.sh` | In-container guide (available ML packages & workflows) | — |

Both `ngc-pytorch.sh` and `ngc-jupyter.sh` use the `nvcr.io/nvidia/pytorch:26.02-py3` image and will auto-install packages from `~/requirements-gpu.txt` if present.

### Data Toolbox

A general-purpose data engineering container for processing, curating, labeling, and synthetic data generation — built for pretraining and fine-tuning data pipelines. Uses the NGC PyTorch base and layers Python-level data tools on top.

| Script | Purpose | Port |
|--------|---------|------|
| `data-toolbox-build.sh` | Build the data-toolbox Docker image (one-time) | — |
| `data-toolbox.sh` | Interactive data processing shell with GPU access | — |
| `data-toolbox-jupyter.sh` | Jupyter Lab with data stack | 8890 |

**Included libraries:**

| Category | Packages |
|----------|----------|
| Processing | pandas, polars, pyarrow, duckdb, datasets |
| Curation & dedup | datatrove, datasketch, mmh3, xxhash, ftfy |
| Web & text extraction | trafilatura, beautifulsoup4, readability-lxml, lxml |
| Document extraction | pdfplumber, python-docx, openpyxl |
| Synthetic generation | distilabel, Faker |
| Data quality | cleanlab |
| Labeling clients | label-studio-sdk, argilla (clients — servers run separately) |
| Cloud I/O | boto3, azure-storage-blob, google-cloud-storage, smart-open |
| Serialization | orjson, msgspec, zstandard |
| CLI | typer, rich, tqdm |
| System tools | DuckDB CLI, csvkit, pigz, parallel, pv, tesseract-ocr, poppler-utils |

Data directories are mounted from the host:

| Host Path | Container Path | Purpose |
|-----------|---------------|---------|
| `~/data/raw` | `/data/raw` | Raw ingested data |
| `~/data/processed` | `/data/processed` | Cleaned and transformed data |
| `~/data/curated` | `/data/curated` | Deduplicated, quality-filtered data |
| `~/data/synthetic` | `/data/synthetic` | Generated synthetic data |
| `~/data/exports` | `/data/exports` | Final exports for training |
| `~/.cache/huggingface` | `/root/.cache/huggingface` | HF model/dataset cache |

```bash
# Build once
data-build

# Interactive shell
data-toolbox

# Jupyter
data-jupyter
```

### Labeling Platforms

Persistent Docker services for data annotation. The data toolbox connects to these as a client via `label-studio-sdk` and `argilla`.

| Script | Purpose | Port |
|--------|---------|------|
| `start-label-studio.sh` | Label Studio with persistent storage | 8081 |
| `start-argilla.sh` | Argilla with persistent storage | 6900 |

```bash
# Start labeling platforms
label-studio        # http://localhost:8081
argilla             # http://localhost:6900 (default: argilla / 1234)

# Stop
label-studio-stop
argilla-stop
```

Data is persisted in `~/label-studio-data` and within the Argilla container volume respectively.

### Eval Toolbox

A general-purpose evaluation container built on the NGC PyTorch base with metrics, LLM eval, CV eval, and Triton client libraries pre-installed. Does **not** reinstall CUDA/PyTorch — only layers Python-level eval packages on top.

| Script | Purpose | Port |
|--------|---------|------|
| `eval-toolbox-build.sh` | Build the eval-toolbox Docker image (one-time) | — |
| `eval-toolbox.sh` | Interactive eval shell with GPU access | — |
| `eval-toolbox-jupyter.sh` | Jupyter Lab with eval stack | 8889 |

**Included libraries:** `lm-eval`, `ragas`, `evaluate`, `datasets`, `torchmetrics`, `pycocotools`, `albumentations`, `scikit-learn`, `pandas`, `scipy`, `wandb`, `mlflow`, `tritonclient[all]`, `typer`, `rich`

Data directories are mounted from the host:

| Host Path | Container Path | Purpose |
|-----------|---------------|---------|
| `~/eval/datasets` | `/datasets` | Evaluation datasets |
| `~/eval/models` | `/models` | Model checkpoints |
| `~/eval/runs` | `/eval_runs` | Run logs and results |
| `~/.cache/huggingface` | `/root/.cache/huggingface` | HF model/dataset cache |

```bash
# Build once
eval-build

# Interactive shell
eval-toolbox

# Jupyter
eval-jupyter
```

### Triton TRT-LLM Server

Runs NVIDIA Triton Inference Server with the TensorRT-LLM backend as a sidecar. The eval toolbox container connects to it via `tritonclient` over HTTP/gRPC.

| Script | Purpose | Ports |
|--------|---------|-------|
| `triton-trtllm.sh` | Full launcher — streams logs | 8010 (HTTP), 8011 (gRPC), 8012 (metrics) |
| `triton-trtllm-sync.sh` | NVIDIA Sync variant — returns immediately | 8010, 8011, 8012 |

Ports are offset from default (8000-8002) to avoid conflict with Unsloth Studio.

Host directories:

| Host Path | Container Path | Purpose |
|-----------|---------------|---------|
| `~/triton/engines` | `/engines` | TensorRT-LLM compiled engines |
| `~/triton/model_repo` | `/triton_model_repo` | Triton model repository |

**Workflow:**

1. Start Triton: `triton` (or `triton-trtllm-sync.sh` for remote)
2. Build TRT-LLM engines inside the container and place in `~/triton/engines`
3. Populate `~/triton/model_repo` with Triton model configs
4. Restart the container — Triton auto-serves from the model repo
5. From the eval toolbox, query via `tritonclient` or HTTP:

```python
# Inside eval-toolbox container
import tritonclient.http as httpclient
client = httpclient.InferenceServerClient("localhost:8010")
client.is_server_live()
```

### Unsloth Studio

| Script | Purpose | Port |
|--------|---------|------|
| `unsloth-studio.sh` | Full launcher — streams logs, auto-opens browser when ready | 8000 |
| `unsloth-studio-sync.sh` | NVIDIA Sync variant — returns immediately, runs in background | 8000 |

Fine-tuning data is persisted in `~/unsloth-data`. Use `unsloth-studio-sync.sh` when launching remotely via NVIDIA Sync (no TTY required). First launch takes up to 30 minutes while dependencies install.

```bash
# Check progress after launching the sync variant
docker logs -f unsloth-studio
```

### Workflow Automation

| Script | Purpose | Port |
|--------|---------|------|
| `start-n8n.sh` | n8n automation platform with persistent config | 5678 |

Data is persisted in `~/.n8n`.

## Port Reference

| Port | Service |
|------|---------|
| 4000 | LiteLLM Proxy |
| 5678 | n8n |
| 6900 | Argilla |
| 8000 | Unsloth Studio |
| 8010 | Triton TRT-LLM (HTTP) |
| 8011 | Triton TRT-LLM (gRPC) |
| 8012 | Triton TRT-LLM (metrics) |
| 8020 | vLLM |
| 8080 | code-server |
| 8081 | Label Studio |
| 8888 | Jupyter Lab (NGC) |
| 8889 | Jupyter Lab (Eval Toolbox) |
| 8890 | Jupyter Lab (Data Toolbox) |
| 11434 | Ollama |
| 12000 | Open-WebUI |

## Remote Access via NVIDIA Sync

[NVIDIA Sync](https://docs.nvidia.com/dgx/dgx-spark/nvidia-sync.html#spark-nvidia-sync) lets you run commands on your DGX Spark from your laptop and forward ports for browser-based tools.

### Setup

1. Install and configure NVIDIA Sync on your client machine per the [official docs](https://docs.nvidia.com/dgx/dgx-spark/nvidia-sync.html#spark-nvidia-sync).

2. Clone this repo on the DGX:
   ```bash
   nvidia-sync exec -- git clone <repo-url> ~/dgx-toolbox
   ```

3. Run the base setup:
   ```bash
   nvidia-sync exec -- bash ~/dgx-toolbox/dgx-global-base-setup.sh
   ```

4. Build toolbox images:
   ```bash
   nvidia-sync exec -- bash ~/dgx-toolbox/eval-toolbox-build.sh
   nvidia-sync exec -- bash ~/dgx-toolbox/data-toolbox-build.sh
   ```

5. Enable Ollama remote access:
   ```bash
   nvidia-sync exec -- bash ~/dgx-toolbox/setup-ollama-remote.sh
   ```

### Launching Tools Remotely

For **background services**, launch with `nvidia-sync exec` and then forward the port:

```bash
# Open-WebUI
nvidia-sync exec -- bash ~/dgx-toolbox/start-open-webui-sync.sh
nvidia-sync forward 12000

# vLLM
nvidia-sync exec -- bash ~/dgx-toolbox/start-vllm-sync.sh meta-llama/Llama-3.1-8B-Instruct
nvidia-sync forward 8020

# LiteLLM
nvidia-sync exec -- bash ~/dgx-toolbox/start-litellm-sync.sh
nvidia-sync forward 4000

# Unsloth Studio
nvidia-sync exec -- bash ~/dgx-toolbox/unsloth-studio-sync.sh
nvidia-sync forward 8000

# n8n
nvidia-sync exec -- bash ~/dgx-toolbox/start-n8n.sh &
nvidia-sync forward 5678

# Triton TRT-LLM
nvidia-sync exec -- bash ~/dgx-toolbox/triton-trtllm-sync.sh
nvidia-sync forward 8010

# Label Studio
nvidia-sync exec -- bash ~/dgx-toolbox/start-label-studio.sh &
nvidia-sync forward 8081

# Argilla
nvidia-sync exec -- bash ~/dgx-toolbox/start-argilla.sh &
nvidia-sync forward 6900
```

For **interactive containers**, use `nvidia-sync exec -it`:

```bash
nvidia-sync exec -it -- bash ~/dgx-toolbox/ngc-pytorch.sh
nvidia-sync exec -it -- bash ~/dgx-toolbox/eval-toolbox.sh
nvidia-sync exec -it -- bash ~/dgx-toolbox/data-toolbox.sh
```

For **Jupyter Lab**:

```bash
nvidia-sync exec -- bash ~/dgx-toolbox/ngc-jupyter.sh &
nvidia-sync forward 8888

nvidia-sync exec -- bash ~/dgx-toolbox/eval-toolbox-jupyter.sh &
nvidia-sync forward 8889

nvidia-sync exec -- bash ~/dgx-toolbox/data-toolbox-jupyter.sh &
nvidia-sync forward 8890
```

### NVIDIA Sync Custom App Configuration

Register these tools as custom apps in NVIDIA Sync so they appear in the Sync UI. Add one entry per app — Sync supports one port per custom app.

| App Name | Command | Port | Auto-open |
|----------|---------|------|-----------|
| Open-WebUI | `bash ~/dgx-toolbox/start-open-webui-sync.sh` | 12000 | Yes |
| LiteLLM | `bash ~/dgx-toolbox/start-litellm-sync.sh` | 4000 | No |
| Unsloth Studio | `bash ~/dgx-toolbox/unsloth-studio-sync.sh` | 8000 | Yes |
| n8n | `bash ~/dgx-toolbox/start-n8n.sh` | 5678 | Yes |
| Label Studio | `bash ~/dgx-toolbox/start-label-studio.sh` | 8081 | Yes |
| Argilla | `bash ~/dgx-toolbox/start-argilla.sh` | 6900 | Yes |
| Eval Jupyter | `bash ~/dgx-toolbox/eval-toolbox-jupyter.sh` | 8889 | Yes |
| Data Jupyter | `bash ~/dgx-toolbox/data-toolbox-jupyter.sh` | 8890 | Yes |
| NGC Jupyter | `bash ~/dgx-toolbox/ngc-jupyter.sh` | 8888 | Yes |
| Triton TRT-LLM | `bash ~/dgx-toolbox/triton-trtllm-sync.sh` | 8010 | No |
| vLLM | `bash ~/dgx-toolbox/start-vllm-sync.sh meta-llama/Llama-3.1-8B-Instruct` | 8020 | No |

Refer to the [NVIDIA Sync custom apps documentation](https://docs.nvidia.com/dgx/dgx-spark/nvidia-sync.html#spark-nvidia-sync) for the exact configuration format.

### Port Forwarding Summary

```bash
nvidia-sync forward 4000    # LiteLLM Proxy
nvidia-sync forward 5678    # n8n
nvidia-sync forward 6900    # Argilla
nvidia-sync forward 8000    # Unsloth Studio
nvidia-sync forward 8010    # Triton TRT-LLM (HTTP)
nvidia-sync forward 8011    # Triton TRT-LLM (gRPC)
nvidia-sync forward 8020    # vLLM
nvidia-sync forward 8080    # code-server
nvidia-sync forward 8081    # Label Studio
nvidia-sync forward 8888    # Jupyter Lab (NGC)
nvidia-sync forward 8889    # Jupyter Lab (Eval Toolbox)
nvidia-sync forward 8890    # Jupyter Lab (Data Toolbox)
nvidia-sync forward 11434   # Ollama
nvidia-sync forward 12000   # Open-WebUI
```

## Suggested Aliases

Add these to your `~/.bash_aliases` on the **DGX Spark**:

```bash
# --- DGX Toolbox aliases ---
alias dgx-setup='bash ~/dgx-toolbox/dgx-global-base-setup.sh'
alias pytorch='bash ~/dgx-toolbox/ngc-pytorch.sh'
alias jupyter='bash ~/dgx-toolbox/ngc-jupyter.sh'
alias unsloth='bash ~/dgx-toolbox/unsloth-studio.sh'
alias unsloth-stop='docker stop unsloth-studio && docker rm unsloth-studio'
alias n8n='bash ~/dgx-toolbox/start-n8n.sh'
alias n8n-stop='docker stop n8n'
alias eval-build='bash ~/dgx-toolbox/eval-toolbox-build.sh'
alias eval-toolbox='bash ~/dgx-toolbox/eval-toolbox.sh'
alias eval-jupyter='bash ~/dgx-toolbox/eval-toolbox-jupyter.sh'
alias triton='bash ~/dgx-toolbox/triton-trtllm.sh'
alias triton-stop='docker stop triton-trtllm'
alias data-build='bash ~/dgx-toolbox/data-toolbox-build.sh'
alias data-toolbox='bash ~/dgx-toolbox/data-toolbox.sh'
alias data-jupyter='bash ~/dgx-toolbox/data-toolbox-jupyter.sh'
alias label-studio='bash ~/dgx-toolbox/start-label-studio.sh'
alias label-studio-stop='docker stop label-studio'
alias argilla='bash ~/dgx-toolbox/start-argilla.sh'
alias argilla-stop='docker stop argilla'
alias open-webui='bash ~/dgx-toolbox/start-open-webui.sh'
alias open-webui-stop='docker stop open-webui'
alias vllm='bash ~/dgx-toolbox/start-vllm.sh'
alias vllm-stop='docker stop vllm && docker rm vllm'
alias litellm='bash ~/dgx-toolbox/start-litellm.sh'
alias litellm-stop='docker stop litellm'
alias ollama-remote='bash ~/dgx-toolbox/setup-ollama-remote.sh'
```

For your **client machine** (remote via NVIDIA Sync):

```bash
# --- Remote DGX aliases ---
alias dgx-open-webui='nvidia-sync exec -- bash ~/dgx-toolbox/start-open-webui-sync.sh && nvidia-sync forward 12000'
alias dgx-litellm='nvidia-sync exec -- bash ~/dgx-toolbox/start-litellm-sync.sh && nvidia-sync forward 4000'
alias dgx-unsloth='nvidia-sync exec -- bash ~/dgx-toolbox/unsloth-studio-sync.sh && nvidia-sync forward 8000'
alias dgx-n8n='nvidia-sync exec -- bash ~/dgx-toolbox/start-n8n.sh && nvidia-sync forward 5678'
alias dgx-jupyter='nvidia-sync exec -- bash ~/dgx-toolbox/ngc-jupyter.sh & nvidia-sync forward 8888'
alias dgx-eval-jupyter='nvidia-sync exec -- bash ~/dgx-toolbox/eval-toolbox-jupyter.sh & nvidia-sync forward 8889'
alias dgx-data-jupyter='nvidia-sync exec -- bash ~/dgx-toolbox/data-toolbox-jupyter.sh & nvidia-sync forward 8890'
alias dgx-triton='nvidia-sync exec -- bash ~/dgx-toolbox/triton-trtllm-sync.sh && nvidia-sync forward 8010'
alias dgx-label-studio='nvidia-sync exec -- bash ~/dgx-toolbox/start-label-studio.sh & nvidia-sync forward 8081'
alias dgx-argilla='nvidia-sync exec -- bash ~/dgx-toolbox/start-argilla.sh & nvidia-sync forward 6900'
alias dgx-pytorch='nvidia-sync exec -it -- bash ~/dgx-toolbox/ngc-pytorch.sh'
alias dgx-eval='nvidia-sync exec -it -- bash ~/dgx-toolbox/eval-toolbox.sh'
alias dgx-data='nvidia-sync exec -it -- bash ~/dgx-toolbox/data-toolbox.sh'
```

## GPU Requirements File

Both NGC PyTorch scripts auto-install from `~/requirements-gpu.txt` at container start. Create it with your preferred packages:

```bash
cat > ~/requirements-gpu.txt << 'EOF'
unsloth
trl
peft
bitsandbytes
datasets
EOF
```

## License

MIT
