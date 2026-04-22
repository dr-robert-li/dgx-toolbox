# DGX Spark Toolbox

![Version](https://img.shields.io/badge/version-1.5.0-blue)
![Tests](https://github.com/dr-robert-li/dgx-toolbox/actions/workflows/test.yml/badge.svg)
![Python](https://img.shields.io/badge/python-3.10%2B-3776AB?logo=python&logoColor=white)
![Bash](https://img.shields.io/badge/bash-5.0%2B-4EAA25?logo=gnubash&logoColor=white)
![Docker](https://img.shields.io/badge/docker-nvidia-2496ED?logo=docker&logoColor=white)
![NVIDIA](https://img.shields.io/badge/NVIDIA-DGX%20Spark-76B900?logo=nvidia&logoColor=white)
![Platform](https://img.shields.io/badge/platform-aarch64-green)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

**Author:** Dr. Robert Li

Battle-tested scripts for spinning up ML/AI tools on the **NVIDIA DGX Spark**, designed for both local use and remote access via [NVIDIA Sync](https://docs.nvidia.com/dgx/dgx-spark/nvidia-sync.html#spark-nvidia-sync).

## Prerequisites

- NVIDIA DGX Spark (aarch64)
- Docker with NVIDIA Container Toolkit (`--gpus all` support)
- NGC container registry access (`nvcr.io`)
- For remote use: [NVIDIA Sync](https://docs.nvidia.com/dgx/dgx-spark/nvidia-sync.html#spark-nvidia-sync) configured on your client machine
- [sparkrun](https://github.com/spark-arena/sparkrun) — vendored as a git submodule at `vendor/sparkrun` and installed by `setup/dgx-global-base-setup.sh` (requires Python 3.12+ and [uv](https://github.com/astral-sh/uv), which the setup script installs on first run)

### Cloning with submodules

This repo tracks sparkrun as a submodule. Always clone recursively, or initialise the submodule after a plain clone:

```bash
# Recommended
git clone --recurse-submodules <repo-url> ~/dgx-toolbox

# If you already cloned without --recurse-submodules
cd ~/dgx-toolbox && git submodule update --init --recursive
```

The pinned sparkrun commit is stored in `.sparkrun-pin` for reproducibility; the submodule itself tracks `main` so you can bump forward at your discretion (`cd vendor/sparkrun && git pull origin main`).

## Quick Start

```bash
# Clone to your DGX
git clone <repo-url> ~/dgx-toolbox

# Copy aliases
cp ~/dgx-toolbox/example.bash_aliases ~/.bash_aliases && source ~/.bash_aliases

# One-time system setup (Python, Miniconda, pyenv, uv, sparkrun, harness, kaggle)
# Also runs the DGX mode picker (single vs. cluster) on first launch.
bash ~/dgx-toolbox/setup/dgx-global-base-setup.sh
source ~/.bashrc

# Change DGX mode later (or on the fly via --solo / --cluster flags on `vllm`)
dgx-mode single
dgx-mode cluster host-a,host-b,host-c
dgx-mode status

# Optional: configure Kaggle API (for downloading Kaggle datasets)
# Get your key from https://www.kaggle.com/settings → API → Create New Token
mkdir -p ~/.kaggle && chmod 700 ~/.kaggle
echo '{"username":"YOUR_KAGGLE_USERNAME","key":"KGAT_your_key_here"}' > ~/.kaggle/kaggle.json
chmod 600 ~/.kaggle/kaggle.json
# Both username and key are required — find your username at kaggle.com/account

# Build all toolbox images (base → eval + data)
build-all

# Enable Ollama for remote/LAN access
ollama-remote

# Start the OpenAI-compatible proxy (sparkrun wraps LiteLLM, binds 0.0.0.0:4000)
litellm

# Print the LAN URL other devices on your network can use (not just localhost)
# e.g. http://10.24.11.13:4000/v1 → point any OpenAI-compatible client here.
LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo "Proxy (local):  http://localhost:4000/v1"
echo "Proxy (LAN):    http://${LAN_IP}:4000/v1"
# Locked-down alternative — only listen on localhost:
#   sparkrun proxy start --host 127.0.0.1
# LAN with auth:
#   sparkrun proxy start --master-key sk-choose-a-long-random-string

# Serve a model via a sparkrun recipe (single-node by default, or --cluster NAME)
vllm nemotron-3-nano-4b-bf16-vllm

# Check what's running
dgx-status
```

### Downloading new models from Hugging Face

vLLM (via sparkrun) loads models straight from the Hugging Face cache at
`~/.cache/huggingface` — the runtime exports `HF_HOME=/cache/huggingface` inside
the container and bind-mounts the host cache in, so anything you pull on the
host is visible to every recipe. You only need to download a model once per
box; every subsequent recipe that references it starts instantly.

#### 1. Install the `hf` CLI and authenticate

```bash
# ARM64-native wheel, no compile step.
pip install -U "huggingface_hub[cli]" hf_xet

# One-time login (stores a token at ~/.cache/huggingface/token).
# Only needed for gated repos (Llama, Nemotron, etc.) — public models work anonymously.
hf auth login
# Or non-interactively:
# hf auth login --token "$HF_TOKEN"
```

`hf` is the current Hugging Face CLI — the old `huggingface-cli` name still
works as an alias but is being phased out ([announcement](https://huggingface.co/blog/hf-cli)).

#### 2. Download a model

```bash
# Full repo — most common for serving.
hf download nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16

# Just the files you need (handy for very large repos):
hf download Qwen/Qwen3-1.7B --include "*.safetensors" "*.json" "tokenizer*"

# Optional: speed up big downloads on a fast link (Xet-backed repos).
# Replaces the deprecated HF_HUB_ENABLE_HF_TRANSFER path — huggingface_hub v1.x
# removed hf_transfer; use the Xet knobs instead.
export HF_XET_HIGH_PERFORMANCE=1
```

The model lands at `~/.cache/huggingface/hub/models--<org>--<name>/`. sparkrun
reuses whatever is already there — no explicit import step.

#### 3. Serve it via a registered recipe

Sparkrun resolves recipes by name from registered registries. Two upstream
registries are provisioned automatically during `setup/dgx-global-base-setup.sh`
and can be refreshed any time via the `dgx-recipes` alias:

- [**Official recipes**](https://github.com/spark-arena/recipe-registry) — maintained and Blackwell-tested by the Spark Arena team.
- [**Community recipes**](https://github.com/spark-arena/community-recipe-registry) — contributed by users; benchmark entries are surfaced at [Spark Arena](https://spark-arena.com).

```bash
dgx-recipes add      # register defaults (idempotent — safe to re-run)
dgx-recipes list     # show what's registered
dgx-recipes update   # git-pull every enabled registry; restore missing defaults
dgx-recipes status   # summary + the URLs this script installs

# Run any recipe by name — sparkrun pulls the model on first launch if needed:
vllm qwen3-1.7b-vllm
# or directly via sparkrun:
sparkrun run qwen3-1.7b-vllm
```

For anything not in those registries, drop a YAML file into
`~/dgx-toolbox/recipes/` (the local recipe directory the `vllm` alias already
searches) and use `recipes/nemotron-3-nano-4b-bf16-vllm.yaml` as a template.
See [`recipes/README.md`](recipes/README.md) for the schema and sm_121
container guidance.

#### 4. Route the model through the proxy

Once the recipe is running, sparkrun's autodiscover sweep (every 30s) registers
it with the `:4000` proxy automatically. To force an immediate refresh or pin
a short stable alias:

```bash
litellm-models                              # refresh + list routed models
sparkrun proxy alias add fast  Qwen/Qwen3-1.7B
sparkrun proxy alias add smart Qwen/Qwen3-8B
```

Clients (Claude Code via `claude-litellm`, Open-WebUI, the harness, any
OpenAI-compatible SDK) then talk to the alias:

```bash
curl http://${LAN_IP:-localhost}:4000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"fast","messages":[{"role":"user","content":"hi"}]}'
```

Repointing `fast` at a different backing model later is one `alias add` away —
no client reconfiguration needed.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                      DGX Toolbox                             │
├──────────────┬──────────────┬──────────────┬─────────────────┤
│  Inference   │    Data      │  Evaluation  │  Fine-Tuning    │
│              │              │              │                 │
│ Open-WebUI   │ data-toolbox │ eval-toolbox │ Unsloth Studio  │
│ Ollama       │ Label Studio │ lm-eval      │                 │
│ sparkrun     │ Argilla      │ Triton       │                 │
│ (vLLM+proxy) │ distilabel   │ tritonclient │                 │
├──────────────┴──────────────┴──────────────┴─────────────────┤
│  Safety Harness (FastAPI :5000)                               │
│  Auth │ Guardrails │ Critique │ Evals │ Red Team │ HITL      │
├──────────────────────────────────────────────────────────────┤
│  GPU Telemetry (pip install -e telemetry/)                    │
│  GPUSampler │ UMA Model │ Anchor Store │ Probe │ Classifier  │
├──────────────────────────────────────────────────────────────┤
│  Shared: base-toolbox image │ lib.sh │ docker-compose        │
├──────────────────────────────────────────────────────────────┤
│  NGC PyTorch base (nvcr.io/nvidia/pytorch:26.02-py3)         │
└──────────────────────────────────────────────────────────────┘
```

### Image Hierarchy

```
nvcr.io/nvidia/pytorch:26.02-py3  (21GB, CUDA + PyTorch)
  └─ base-toolbox                 (shared: pandas, pyarrow, datasets, openai, scikit-learn, typer, rich,
                                    transformers, accelerate, peft, trl, sentencepiece, hf_transfer, pyyaml)
       ├─ eval-toolbox            (+lm-eval, ragas, torchmetrics, mlflow, tritonclient)
       └─ data-toolbox            (+polars, duckdb, datatrove, distilabel, cleanlab, trafilatura, pdfplumber)
```

Shared layers mean `eval-toolbox` and `data-toolbox` rebuild in seconds when only their specific packages change.

## Scripts

### System Setup & Operations

| Script | Purpose |
|--------|---------|
| `setup/dgx-global-base-setup.sh` | Idempotent system init — installs build tools, Miniconda (aarch64), and pyenv |
| `inference/setup-ollama-remote.sh` | Reconfigure Ollama to listen on all interfaces for Sync/LAN access (requires sudo) |
| `build-toolboxes.sh` | Build all Docker images: base → eval + data (alias: `build-all`) |
| `status.sh` | Show all services, image sizes, and disk usage (alias: `dgx-status`) |
| `lib.sh` | Shared functions for launcher scripts (sourced, not run directly) |

### Extra Bind Mounts

All container scripts support mounting additional host directories via the `EXTRA_MOUNTS` environment variable. This is useful for mounting project directories into containers without modifying scripts.

```bash
# Mount a single project directory
EXTRA_MOUNTS="$HOME/Desktop/projects/wp-finetune:/workspace/wp-finetune" unsloth-studio

# Mount multiple directories (comma-separated)
EXTRA_MOUNTS="/data/models:/workspace/models,/data/datasets:/workspace/datasets" ngc-pytorch
```

Docker does not follow host symlinks, so bind-mounting is the correct way to make host directories visible inside containers.

### Inference Playground

Tools for serving models and interacting with them — chat, code, agentic workflows. Covers both web UIs for non-technical users and CLI/API access for technical users.

#### Docker Compose (Open-WebUI only) + sparkrun

The compose file now ships only the Open-WebUI GUI container. Model serving and the OpenAI-compatible proxy are delegated to [sparkrun](https://github.com/spark-arena/sparkrun), vendored at `vendor/sparkrun`. The `inference-up` / `inference-down` aliases start/stop both layers together:

```bash
# Start Open-WebUI (:12000) + sparkrun proxy (:4000)
inference-up

# Stop both
inference-down

# Stream Open-WebUI logs (sparkrun has its own: vllm-logs)
inference-logs
```

Individual helpers (`open-webui`, `open-webui-stop`, `sparkrun ...`) still work for standalone use and NVIDIA Sync custom apps.

#### Open-WebUI (Chat Interface)

| Script | Purpose | Port |
|--------|---------|------|
| `inference/start-open-webui.sh` | Open-WebUI with bundled Ollama — streams logs | 12000 |
| `inference/start-open-webui-sync.sh` | NVIDIA Sync variant — returns immediately | 12000 |

Full-featured chat interface with RAG, image generation, multi-model support, and conversation history. Uses the `ghcr.io/open-webui/open-webui:ollama` image with bundled Ollama. Data persisted in Docker volumes `open-webui` and `open-webui-ollama`.

```bash
open-webui          # http://localhost:12000
open-webui-stop
```

**Connecting to inference backends:** Open-WebUI can access all three inference services. Configure them in Admin Panel → Settings → Connections:

| Backend | Connection Type | URL | API Key |
|---------|----------------|-----|---------|
| Bundled Ollama | Ollama (pre-configured) | — | — |
| Host Ollama | Ollama | `http://host.docker.internal:11434` | — |
| sparkrun workload (vLLM) | OpenAI API | `http://host.docker.internal:8000/v1` | `none` |
| sparkrun proxy (LiteLLM) | OpenAI API | `http://host.docker.internal:4000/v1` | `none` |

Once added, all models from all backends appear in Open-WebUI's model dropdown. If you're running the sparkrun proxy, you only need to add the proxy — it already routes to Ollama and the active sparkrun workload (plus cloud APIs), so one connection covers everything.

#### sparkrun (model serving + OpenAI-compatible proxy)

[sparkrun](https://github.com/spark-arena/sparkrun) is the replacement for this repo's hand-rolled `start-vllm.sh` / `start-litellm.sh` launchers. It's an Apache-2.0 Python CLI that starts recipe-defined vLLM workloads (single-node or multi-node) and manages a LiteLLM-backed OpenAI-compatible proxy on `:4000` — the same port the legacy LiteLLM launcher used, so downstream tools (harness, eval, Open-WebUI) need no changes.

It is vendored as a git submodule at `vendor/sparkrun` and installed by `setup/dgx-global-base-setup.sh` via `uv tool install --force --editable vendor/sparkrun`.

**Recipes live in two places:**

| Path | Purpose |
|------|---------|
| `vendor/sparkrun/recipes/` (read-only) | Official recipes maintained upstream (`minimax-m2.7`, `qwen3-coder-next`, `qwen3-vl`, `qwen3.6`, …) |
| `recipes/` (this repo) | Project-specific recipes: `nemotron-3-nano-4b-bf16-vllm` (default model, replaces the old `example.vllm-model`) and `eval-checkpoint` (ephemeral eval workload used by `scripts/eval-checkpoint.sh`) |

Both directories are passed on the command line via `--recipe-path` when needed.

**Model serving (`vllm` alias → `sparkrun run`):**

```bash
# Default recipe (honours dgx-mode: single or cluster)
vllm nemotron-3-nano-4b-bf16-vllm

# Force single-node on this invocation
vllm nemotron-3-nano-4b-bf16-vllm --solo

# Use a named cluster or an explicit host list
vllm nemotron-3-nano-4b-bf16-vllm --cluster my-cluster
vllm nemotron-3-nano-4b-bf16-vllm --hosts host-a,host-b

# Manage the workload
vllm-status    # sparkrun status
vllm-logs      # sparkrun logs
vllm-show      # sparkrun show  (resolved recipe config)
vllm-stop      # sparkrun stop

# Query the OpenAI-compatible endpoint (port defaults to the recipe's value, :8000)
curl http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16", "messages": [{"role": "user", "content": "Hello"}]}'
```

Host selection precedence: CLI flag > `~/.config/dgx-toolbox/mode.env` (written by `dgx-mode`) > `sparkrun`'s named cluster > `sparkrun`'s default cluster.

**OpenAI-compatible proxy (`litellm` alias → `sparkrun proxy`):**

The proxy is sparkrun's supervised `litellm[proxy]` instance. It binds `:4000` by default and auto-routes to the active sparkrun workload plus any aliases you add.

```bash
litellm                       # sparkrun proxy start  (http://localhost:4000)
litellm-status                # sparkrun proxy status
litellm-models                # sparkrun proxy models --refresh
litellm-alias add claude-sonnet anthropic/claude-sonnet-4-20250514
litellm-stop                  # sparkrun proxy stop
```

**Custom aliases / cloud routing:** Use `sparkrun proxy alias add` to register additional upstreams. Cloud API keys live in the environment sparkrun inherits (e.g. in `~/.bashrc`):

```bash
export OPENAI_API_KEY=sk-...
export ANTHROPIC_API_KEY=sk-ant-...
export GEMINI_API_KEY=AI...
```

**Finding models:** Browse compatible models at [vLLM Supported Models](https://docs.vllm.ai/en/latest/models/supported_models.html) and on [HuggingFace](https://huggingface.co/models?apps=vllm&sort=trending). Any HuggingFace model with a supported architecture (Llama, Mistral, Qwen, Gemma, Phi, etc.) works out of the box when referenced from a recipe. HuggingFace cache (`~/.cache/huggingface`) and model checkpoints (`~/eval/models`) are mounted automatically by sparkrun's default Blackwell-tested image, `ghcr.io/spark-arena/dgx-vllm-eugr-nightly:latest`.

**Authoring a new recipe:** Copy `recipes/nemotron-3-nano-4b-bf16-vllm.yaml` as a starting point — `recipe_version: "2"`, fill in `model`, `runtime`, `container`, and `defaults.{port,gpu_memory_utilization,max_model_len}`. Run `sparkrun show <name>` to validate before launching.

**DGX mode (single vs. cluster):**

The first time `setup/dgx-global-base-setup.sh` runs, `setup/dgx-mode-picker.sh` prompts for single-node vs. multi-node usage and writes `~/.config/dgx-toolbox/mode.env`. Change it any time with:

```bash
dgx-mode single                         # one DGX Spark, default cluster = solo
dgx-mode cluster host-a,host-b,host-c   # multi-node, writes DGX_HOSTS
dgx-mode status                         # show resolved mode + hosts
```

Every sparkrun invocation inherits this setting but can still be overridden on the fly with `--solo`, `--cluster NAME`, or `--hosts h1,h2,…`.

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
│ Ollama │ :11434    │  sparkrun  │ :4000      │ sparkrun   │ :8000
│ (local │           │   proxy    │            │ workload   │
│  LLMs) │           │ (LiteLLM)  │            │ (vLLM,     │
└────────┘           └─────┬──────┘            │ OpenAI     │
                           │                 │ compat)    │
              routes to any backend:            └────────────┘
              Ollama, sparkrun workload,
              OpenAI, Anthropic, Gemini, etc.
```

### Cross-Tool Integrations

All toolbox containers can reach host inference services (Ollama, sparkrun workload, sparkrun proxy) via `host.docker.internal`. Data and model directories are cross-mounted so the toolboxes share artifacts.

**Eval Toolbox → Inference backends:**

```bash
# Inside eval-toolbox: evaluate a model served by the sparkrun workload
lm_eval --model local-completions \
  --model_args model=nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16,base_url=http://host.docker.internal:8000/v1,tokenizer_backend=huggingface \
  --tasks hellaswag,arc_easy

# Or evaluate via the sparkrun proxy (any model routed through it)
lm_eval --model local-completions \
  --model_args model=claude-sonnet,base_url=http://host.docker.internal:4000/v1 \
  --tasks mmlu
```

**Data Toolbox → Synthetic data generation via local models:**

```python
# Inside data-toolbox: use distilabel with the sparkrun proxy
from distilabel.llms import OpenAILLM
from distilabel.steps.tasks import TextGeneration

llm = OpenAILLM(
    model="llama3.1",
    base_url="http://host.docker.internal:4000/v1",
    api_key="none",
)
```

**n8n → sparkrun proxy:** In n8n's OpenAI-compatible nodes, set the base URL to `http://host.docker.internal:4000/v1` to access all local and cloud models.

**Cross-mounts:**

| Container | Extra Mount | Access |
|-----------|------------|--------|
| eval-toolbox | `~/data/exports` → `/data/exports` | Read curated training data |
| data-toolbox | `~/eval/models` → `/models` | Read fine-tuned model checkpoints |

### GPU Containers

| Script | Purpose | Port |
|--------|---------|------|
| `containers/ngc-pytorch.sh` | Interactive PyTorch shell with GPU access | — |
| `containers/ngc-jupyter.sh` | Jupyter Lab on NGC PyTorch container | 8888 |
| `containers/ngc-quickstart.sh` | In-container guide (available ML packages & workflows) | — |

Both `ngc-pytorch.sh` and `ngc-jupyter.sh` use the `nvcr.io/nvidia/pytorch:26.02-py3` image and will auto-install packages from `~/requirements-gpu.txt` if present.

### Data Toolbox

A general-purpose data engineering container for processing, curating, labeling, and synthetic data generation — built for pretraining and fine-tuning data pipelines. Built on `base-toolbox` with data-specific packages layered on top.

| Script | Purpose | Port |
|--------|---------|------|
| `data/data-toolbox-build.sh` | Build the data-toolbox Docker image (auto-builds base if needed) | — |
| `data/data-toolbox.sh` | Interactive data processing shell with GPU access | — |
| `data/data-toolbox-jupyter.sh` | Jupyter Lab with data stack | 8890 |

**Docker Compose:** Label Studio and Argilla can be started together:

```bash
data-stack-up       # starts Label Studio + Argilla
data-stack-down     # stops both
```

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
# Build once (auto-builds base if needed)
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
| `data/start-label-studio.sh` | Label Studio with persistent storage | 8081 |
| `data/start-argilla.sh` | Argilla with persistent storage | 6900 |

```bash
# Start individually
label-studio        # http://localhost:8081
argilla             # http://localhost:6900 (default: argilla / 1234)

# Or start together via compose
data-stack-up

# Stop
label-studio-stop
argilla-stop
```

Data is persisted in `~/label-studio-data` and within the Argilla container volume respectively.

### Eval Toolbox

A general-purpose evaluation container built on `base-toolbox` with metrics, LLM eval, CV eval, and Triton client libraries. Does **not** reinstall CUDA/PyTorch — only layers eval-specific packages on top.

| Script | Purpose | Port |
|--------|---------|------|
| `eval/eval-toolbox-build.sh` | Build the eval-toolbox Docker image (auto-builds base if needed) | — |
| `eval/eval-toolbox.sh` | Interactive eval shell with GPU access | — |
| `eval/eval-toolbox-jupyter.sh` | Jupyter Lab with eval stack | 8889 |

**Included libraries:** `lm-eval`, `ragas`, `evaluate`, `datasets`, `torchmetrics`, `pycocotools`, `albumentations`, `scikit-learn`, `pandas`, `scipy`, `mlflow`, `tritonclient[all]`, `openai`, `typer`, `rich`

Data directories are mounted from the host:

| Host Path | Container Path | Purpose |
|-----------|---------------|---------|
| `~/eval/datasets` | `/datasets` | Evaluation datasets |
| `~/eval/models` | `/models` | Model checkpoints |
| `~/eval/runs` | `/eval_runs` | Run logs and results |
| `~/.cache/huggingface` | `/root/.cache/huggingface` | HF model/dataset cache |

```bash
# Build once (auto-builds base if needed)
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
| `eval/triton-trtllm.sh` | Full launcher — streams logs | 8010 (HTTP), 8011 (gRPC), 8012 (metrics) |
| `eval/triton-trtllm-sync.sh` | NVIDIA Sync variant — returns immediately | 8010, 8011, 8012 |

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
| `containers/unsloth-studio.sh` | Full launcher — streams logs, auto-opens browser when ready | 8000 |
| `containers/unsloth-studio-sync.sh` | NVIDIA Sync variant — returns immediately, runs in background | 8000 |

Fine-tuning data is persisted in `~/unsloth-data`. Use `unsloth-studio-sync.sh` when launching remotely via NVIDIA Sync (no TTY required). First launch takes up to 30 minutes while dependencies install.

```bash
# Check progress after launching the sync variant
docker logs -f unsloth-studio
```

### Workflow Automation

| Script | Purpose | Port |
|--------|---------|------|
| `containers/start-n8n.sh` | n8n automation platform with persistent config | 5678 |

Data is persisted in `~/.n8n`.

### Autonomous Research (Karpathy autoresearch)

| Script | Purpose |
|--------|---------|
| `karpathy-autoresearch/launch-autoresearch.sh` | Interactive launcher — clone/pull, data source menu, DGX Spark tuning, setup |
| `karpathy-autoresearch/launch-autoresearch-sync.sh` | NVIDIA Sync variant — headless, configured via env vars |
| `karpathy-autoresearch/spark-config.sh` | DGX Spark GPU tuning overrides (6,144 CUDA cores, 128 GB unified memory) |

Wraps [karpathy/autoresearch](https://github.com/karpathy/autoresearch) — an autonomous AI agent that runs a tight loop: modify `train.py` → train for 8 minutes → evaluate → commit improvements or revert → repeat (~7 experiments/hour).

```bash
# Interactive — clone repo, select data source, apply Spark tuning
autoresearch

# Headless with HuggingFace dataset
AUTORESEARCH_DATA_SOURCE=huggingface \
AUTORESEARCH_DATA_PATH=karpathy/climbmix-400b-shuffle \
  ~/dgx-toolbox/karpathy-autoresearch/launch-autoresearch-sync.sh
```

**Data sources:** built-in default, local directory, HuggingFace Hub, GitHub repo, or Kaggle dataset. See `karpathy-autoresearch/README.md` for full details.

**DGX Spark tuning:** Parameters are automatically scaled for the Blackwell GB10 (6,144 CUDA cores, 192 Tensor Cores, 128 GB LPDDR5x). Skip with `AUTORESEARCH_SKIP_TUNE=1`. Edit `spark-config.sh` to customize.

### Autoresearch Pipeline (Data to Inference)

End-to-end pipeline that takes a dataset through autoresearch training, post-training safety evaluation, and automatic model registration for inference behind the safety harness.

#### Quick Start

```bash
# Run the pipeline demo (1 baseline training cycle, ~8 min)
demo-autoresearch

# Or with more cycles
DEMO_CYCLES=3 bash ~/dgx-toolbox/scripts/demo-autoresearch.sh
```

#### Pipeline Stages

**Stage 1: Data Source Selection**

The demo presents a 6-option menu to choose your training data:

| Option | Source |
|--------|--------|
| 1 | Built-in default (no setup required — best for quick test) |
| 2 | Local directory from your filesystem |
| 3 | HuggingFace dataset (e.g. `karpathy/climbmix-400b-shuffle`) |
| 4 | GitHub repository |
| 5 | Kaggle dataset (requires kaggle CLI) |
| 6 | Local datasets auto-discovered from `~/data/` |

Expected output: `"Select training data source:"` followed by numbered options. For a quick test, option 1 works without any setup.

**Stage 2: Training Data Screening (Optional)**

Pre-screens your training data through the safety harness guardrails to remove PII, toxicity, and other problematic content before training.

```bash
# Run screening manually (requires harness on :5000)
scripts/screen-data.sh ~/data/my-dataset/train.jsonl
```

Expected output: `"Screened: N total, N clean, N removed."`

If harness is not running, the demo skips screening with a warning and continues.

**Stage 3: Autoresearch Training**

Runs for `DEMO_CYCLES` cycles (default 1 baseline, ~8 min each on DGX Spark).

- DGX Spark tuning applied automatically: batch sizes, seq length, torch.compile disabled, flash-attn3 replaced with SDPA (GB10 CUDA 12.1 compatibility)
- Checkpoints saved only on `val_bpb` improvement (no disk buildup in autonomous mode) to `~/autoresearch/checkpoint/model_<epoch>.pt` with `model.pt` symlink to latest best
- HuggingFace token prompt on first run (cached for future sessions)
- Training output teed to both terminal and `~/dgx-toolbox/demo-training.log`
- Press Enter at any input prompt to go back to the data source menu

Expected output: autoresearch training progress showing loss and eval metrics.

> **Note:** The demo runs training only (no autonomous code modifications between cycles). For the full autonomous research agent that modifies `train.py` between cycles, see [Autonomous Agent Mode](#autonomous-agent-mode) below.

**Stage 4: Safety Eval**

Automatically runs `scripts/eval-checkpoint.sh` after training completes. Supports two checkpoint formats:

- **HuggingFace format** (has `config.json`): Launches the ephemeral `eval-checkpoint` sparkrun recipe (vLLM container on `:8021`), runs the 40-case safety replay, auto-registers passing models with the sparkrun proxy via `sparkrun proxy alias add`
- **PyTorch raw** (has `model.pt`): Extracts training metrics (val_bpb, steps, tokens), writes `safety-eval.json` — custom architectures can't be served via vLLM

```bash
# Run eval manually against any checkpoint
scripts/eval-checkpoint.sh ~/autoresearch/checkpoint
```

Expected output: `"NEW BEST: 0.95 < 0.99"` for improved checkpoints, or `"skipped"` if no improvement.

**Stage 5: Query the Model**

If safety eval passed, the demo summary prints a copy-pasteable curl command:

```bash
curl -s -X POST http://localhost:5000/v1/chat/completions \
  -H "Authorization: Bearer sk-devteam-test" \
  -H "Content-Type: application/json" \
  -d '{"model": "autoresearch/<experiment-name>", "messages": [{"role": "user", "content": "Hello"}]}'
```

#### Manual Pipeline

Run each stage individually for more control:

```bash
# 1. Launch autoresearch interactively
autoresearch

# 2. Screen data (optional, requires harness on :5000)
scripts/screen-data.sh ~/data/my-dataset/train.jsonl

# 3. After training, evaluate the checkpoint
scripts/eval-checkpoint.sh ~/autoresearch/experiments/<experiment>/checkpoint

# 4. If eval fails, check why
cat ~/autoresearch/experiments/<experiment>/checkpoint/safety-eval.json

# 5. Deregister a model when no longer needed
scripts/autoresearch-deregister.sh autoresearch/<experiment-name>
```

#### Troubleshooting

| Problem | Solution |
|---------|----------|
| "Harness not reachable" | Start harness: `harness` (port 5000) |
| Training OOM | Reduce batch size in `spark-config.sh` or set `AUTORESEARCH_SKIP_TUNE=1` |
| Safety eval FAIL | Checkpoint is preserved — review `safety-eval.json`, adjust constitution or thresholds |
| "No checkpoint found" | Check `~/autoresearch/experiments/` for the latest experiment directory |
| Model not queryable after registration | Run `sparkrun proxy models --refresh` — LiteLLM reads aliases via its management API, no container restart needed |

#### Autonomous Agent Mode

The demo script runs training cycles without modifying the code between cycles. The **full autoresearch experience** uses an LLM agent (Claude Code, Cursor, etc.) that autonomously:

1. Reads training results
2. Modifies `train.py` (architecture, hyperparameters, optimizer)
3. Runs training (~8 min)
4. Evaluates — keeps improvements, reverts failures
5. Repeats indefinitely until you stop it

To run the full autonomous loop:

```bash
# 1. Prepare the data first (use the demo or manually)
cd ~/autoresearch
uv run prepare.py

# 2. Start Claude Code with the autoresearch prompt
claude "Read program.md and begin the experiment loop"
```

The agent reads `program.md` (the experiment protocol) and runs autonomously — ~12 experiments/hour, ~100 overnight. Each experiment modifies `train.py`, trains, evaluates, and commits or reverts. You wake up to a git history of experimental results.

**After the agent finishes**, run safety eval and register the best checkpoint:

```bash
# Evaluate the final checkpoint
scripts/eval-checkpoint.sh ~/autoresearch

# If it passes, it's auto-registered and queryable:
curl -s -X POST http://localhost:5000/v1/chat/completions \
  -H "Authorization: Bearer sk-devteam-test" \
  -H "Content-Type: application/json" \
  -d '{"model": "autoresearch/<experiment>", "messages": [{"role": "user", "content": "Hello"}]}'
```

**LLM API for the agent:** The agent needs an LLM API. Claude Code uses your Anthropic API key directly. Alternatively, point it at the sparkrun proxy (`http://localhost:4000`) to use any configured model (local or cloud).

> **Tip:** To run the autonomous agent entirely on local models (no cloud API costs), connect Claude Code to Ollama first. Run `ollama pull llama3.1` (or any capable model), then configure Claude Code to use `http://localhost:11434` as its model provider. The agent loop works with any model that can read code and suggest edits — larger models (70B+) produce better experiments.

#### Without a GPU

Without a GPU, you can skip training and test the eval and registration pipeline with any existing HF-format checkpoint:

```bash
scripts/eval-checkpoint.sh /path/to/checkpoint
```

## Safety Harness

A model-agnostic safety layer that sits between clients and the upstream OpenAI-compatible proxy (sparkrun on `:4000`). All requests are screened through guardrails, constitutional AI critique, and full trace logging before reaching the model — and all outputs are screened before delivery.

### Quick Start

```bash
# 1. Install the harness (first time only)
cd ~/dgx-toolbox/harness && pip install -e ".[test]"

# 2. Start the inference backend
inference-up                                    # Open-WebUI (:12000) + sparkrun proxy (:4000)

# 3. Start a model workload (optional — can use cloud models via the proxy instead)
vllm nemotron-3-nano-4b-bf16-vllm
# Wait for model load: vllm-logs | grep -m1 "startup complete"

# 4. Start the safety harness
harness                                         # http://localhost:5000

# 5. Test it
curl -s -X POST http://localhost:5000/probe \
  -H "Authorization: Bearer sk-devteam-test"
# → {"tenant_id":"dev-team","bypass":false}

# 6. Send a request through the full safety pipeline
curl -s http://localhost:5000/v1/chat/completions \
  -H "Authorization: Bearer sk-devteam-test" \
  -H "Content-Type: application/json" \
  -d '{"model": "nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16",
       "messages": [{"role": "user", "content": "Hello"}]}'
```

**Using with Open-WebUI:** Point Open-WebUI at `http://localhost:5000/v1` instead of the sparkrun proxy's `:4000` to route all chat through the safety pipeline. In Admin Panel → Settings → Connections, add an OpenAI API connection with URL `http://host.docker.internal:5000/v1` and API key `sk-devteam-test`.

**Using with any OpenAI SDK:**

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:5000/v1",
    api_key="sk-devteam-test",
)
response = client.chat.completions.create(
    model="nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16",
    messages=[{"role": "user", "content": "Hello"}],
)
print(response.choices[0].message.content)
```

### Stopping

```bash
harness-stop                # Stop safety harness
vllm-stop                   # Stop sparkrun workload
inference-down              # Stop sparkrun proxy + Open-WebUI
```

### Architecture

```
Clients (Open-WebUI, curl, SDKs)
         │
         ▼
┌──────────────────────────────────────────────────┐
│  Safety Harness (:5000)                           │
│                                                   │
│  Auth → Rate Limit → Unicode Normalize            │
│  → Input Guardrails (content, PII, injection)     │
│  → sparkrun proxy / LiteLLM (:4000)               │
│  → Output Guardrails (toxicity, jailbreak, PII)   │
│  → Constitutional AI Critique (if high-risk)       │
│  → PII-Redacted Trace → SQLite                    │
└──────────────────────────────────────────────────┘
         │
         ▼
    sparkrun proxy (:4000) → Ollama / sparkrun workload / Cloud APIs
```

### Features

| Feature | Description |
|---------|-------------|
| **Multi-tenant auth** | API key auth with per-tenant rate limits (RPM + TPM), allowed models, and bypass flags |
| **Input guardrails** | Unicode normalization, content filtering, PII/secrets detection, prompt injection detection (regex + NeMo LLM-as-judge) |
| **Output guardrails** | Toxicity scanning, jailbreak-success detection, output PII redaction |
| **3 refusal modes** | Hard block (principled refusal), soft steer (LLM rewrite), informative (explains why + suggests alternatives) |
| **Constitutional AI** | High-risk outputs trigger a critique-revise loop against user-editable principles with configurable judge model |
| **PII-safe tracing** | Every request/response logged to SQLite with PII redacted before write |
| **Eval harness** | Replay safety datasets, lm-eval capability benchmarks, CI gate that blocks on regression |
| **Red teaming** | garak vulnerability scans, adversarial prompt generation from near-miss traces, async job dispatch |
| **HITL dashboard** | Gradio review UI with priority-sorted queue, diff view, corrections that feed calibration and fine-tuning |
| **Bypass mode** | Per-tenant bypass flag skips guardrails/critique but still enforces auth and logging |

### Configuration

All config is YAML-based in `harness/config/`:

| File | Purpose |
|------|---------|
| `tenants.yaml` | Tenant API keys (argon2 hashed), rate limits, allowed models, bypass flags, per-tenant rail overrides |
| `rails/rails.yaml` | Guardrail thresholds, enable/disable per rail, refusal modes, critique thresholds |
| `rails/config.yml` | NeMo Guardrails LLMRails configuration |
| `rails/input_output.co` | NeMo Colang flow definitions |
| `constitution.yaml` | Constitutional AI principles (categorized, prioritized, per-principle toggles), judge model selection |
| `redteam.yaml` | Red team settings (max category ratio, near-miss window, variants per trace) |

### HITL Review Dashboard

A Gradio-based review UI for human-in-the-loop safety calibration. Runs as a standalone process that connects to the harness API.

```bash
# Launch the dashboard (harness must be running on :5000)
# Set your API key first (or pass --api-key):
export HARNESS_API_KEY="sk-devteam-test"
hitl
# → http://localhost:8501
```

**What you see:**
- **Top:** Full-width review queue table sorted by priority (most uncertain decisions first), with filters for rail type, tenant, and time range
- **Bottom:** Side-by-side panels — original output (left) and diff/revised output (right). Approve/reject/edit buttons with operator name input

**What corrections do:**
- **Approve** — Revised output was correct; used as positive training example
- **Reject** — Revision was wrong; flags for threshold tightening
- **Edit** — Reviewer writes a better response; used as gold standard

```bash
# Generate threshold suggestions from accumulated corrections
python -m harness.hitl calibrate

# Export corrections as fine-tuning data (OpenAI JSONL format)
python -m harness.hitl export --format jsonl
```

### Eval & CI Tools

```bash
# Run the 40-case safety replay dataset (harness + model must be running)
python -m harness.eval replay \
  --dataset harness/eval/datasets/safety-core.jsonl \
  --api-key sk-devteam-test

# CI regression gate — exits 0 (pass) or 1 (regression detected)
python -m harness.eval gate --tolerance 0.02 --api-key sk-devteam-test

# View metric trends across eval runs
python -m harness.eval trends --last 20

# Constitutional AI tuning suggestions from trace history
python -m harness.critique analyze --since 24h

# Red teaming — promote reviewed adversarial dataset to active evals
python -m harness.redteam promote <file>
python -m harness.redteam list                     # List pending datasets
```

### API Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/v1/chat/completions` | Main proxy endpoint (auth + guardrails + trace) |
| POST | `/probe` | Auth verification test |
| POST | `/admin/suggest-tuning` | AI-guided guardrail/constitution tuning suggestions |
| GET | `/admin/hitl/queue` | Priority-sorted review queue (filters: rail, tenant, since) |
| POST | `/admin/hitl/correct` | Submit correction (approve/reject/edit) |
| POST | `/admin/redteam/jobs` | Submit red team job (garak or deepteam) |
| GET | `/admin/redteam/jobs/{id}` | Poll job status and results |

### Test Tenants

| Tenant | API Key | Bypass |
|--------|---------|--------|
| dev-team | `sk-devteam-test` | No (full pipeline) |
| ci-runner | `sk-ci-test` | Yes (auth + trace only) |

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `HARNESS_PORT` | 5000 | Gateway port |
| `HARNESS_CONFIG_DIR` | `harness/config` | Config directory |
| `HARNESS_DATA_DIR` | `harness/data` | SQLite trace database directory |
| `LITELLM_BASE_URL` | `http://localhost:4000` | Upstream OpenAI-compatible proxy URL (sparkrun by default) |

## Model Store

Tiered model storage management for DGX Spark. Automatically migrates stale models from the hot NVMe drive to a cold drive (external SSD, NAS, or cloud mount) and recalls them on demand. Hot storage stays free for active models while all models remain accessible via symlinks.

### Quick Start

```bash
# One-time setup: configure hot/cold paths, scan existing models, install cron
modelstore init

# Check current state: all models by tier with sizes and last-used timestamps
modelstore status

# Migration runs automatically via cron; run manually to preview
modelstore migrate --dry-run
modelstore migrate
```

### Subcommands

| Command | Description |
|---------|-------------|
| `modelstore init` | Interactive setup wizard — configure hot/cold paths, scan models, install cron |
| `modelstore status` | Show all models by tier with sizes, last-used timestamps, drive totals, watcher/cron status |
| `modelstore migrate` | Move stale models hot→cold (reads stale threshold from config) |
| `modelstore migrate --dry-run` | Preview what would migrate without making changes |
| `modelstore recall <model>` | Move a specific model cold→hot on demand |
| `modelstore revert` | Move all models back to hot, remove symlinks, clean up cron/watcher/cold dirs |
| `modelstore revert --force` | Revert without confirmation prompt |

### How It Works

Models are tracked via a usage watcher (docker events + inotifywait). When a model hasn't been accessed for the configured stale threshold, the cron job migrates it: the model directory is moved to cold storage and replaced with a symlink so tools continue to work transparently. `modelstore recall` reverses this for a specific model; `modelstore revert` restores everything to the original flat-file layout.

Supports HuggingFace (`~/.cache/huggingface/hub/`) and Ollama (`~/.ollama/models/`) storage backends.

## GPU Telemetry

Installable Python package for hardware-aware training on DGX Spark. Any training project can import the telemetry primitives to sample GPU state, calculate memory headroom, classify failures, and persist proven batch configurations — without touching NVML or `/proc` directly.

### Install

```bash
pip install -e ~/dgx-toolbox/telemetry/
```

### Usage

```python
from telemetry.sampler import GPUSampler
from telemetry.uma_model import UMAMemModel
from telemetry.effective_scale import compute
from telemetry.anchor_store import AnchorStore
from telemetry.probe import prepare_probe, evaluate_probe
from telemetry.failure_classifier import classify_failure

# Sample current GPU state (works in mock mode without GPU)
sampler = GPUSampler()
snapshot = sampler.sample()
# → {"watts": 65.0, "temperature_c": 55, "gpu_util_pct": 42,
#    "mem_available_gb": 80.0, "page_cache_gb": 20.0, "mock": False}

# Calculate memory headroom with 5 GB jitter margin
model = UMAMemModel(sampler)
baseline = model.sample_baseline()
headroom = UMAMemModel.calculate_headroom(baseline, snapshot, tier_headroom_pct=20)
# → {"safe_threshold": 21.0, "headroom_gb": 59.0, "headroom_pct": 73.75, ...}

# Classify training outcome
result = classify_failure(snapshot, exit_code=0, training_completed=True)
# → {"classification": "clean", "evidence": {}}
```

### Modules

| Module | Purpose |
|--------|---------|
| `sampler.py` | GPUSampler — NVML metrics + `/proc/meminfo` memory (GB10 UMA safe) |
| `uma_model.py` | Baseline sampling with cache drop, headroom calculation with jitter margin |
| `effective_scale.py` | Multiplier tables (quant, grad ckpt, LoRA, seq len, optimizer) → tier classification |
| `anchor_store.py` | JSON persistence of proven batch configs, SHA-256 keyed, 7-day expiry |
| `probe.py` | Prepare/evaluate cycle for testing new batch size configurations |
| `failure_classifier.py` | Classify training outcomes: clean, oom, hang, thermal, pressure |

### Key Design Decisions

- **No subprocess calls** — all GPU metrics via pynvml direct API, memory via `/proc/meminfo`
- **Mock mode** — automatically activated when `libnvidia-ml.so.1` is absent (CI, containers without GPU passthrough)
- **UMA architecture** — `nvmlDeviceGetMemoryInfo` is never called (raises `NVMLError_NotSupported` on GB10); memory always from `/proc/meminfo` MemAvailable
- **Per-metric degradation** — individual NVML calls fail independently to `None`, never crash `sample()`
- **HANG never produces batch_cap** — prevents incorrect batch backoff on dataloader deadlocks

## Port Reference

| Port | Service |
|------|---------|
| 4000 | sparkrun proxy (LiteLLM) |
| 5000 | Safety Harness |
| 5678 | n8n |
| 6900 | Argilla |
| 8000 | Unsloth Studio **or** sparkrun workload (vLLM) — pick one at a time |
| 8010 | Triton TRT-LLM (HTTP) |
| 8011 | Triton TRT-LLM (gRPC) |
| 8012 | Triton TRT-LLM (metrics) |
| 8021 | sparkrun eval-checkpoint workload (ephemeral) |
| 8080 | code-server |
| 8081 | Label Studio |
| 8501 | HITL Dashboard (Gradio) |
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
   nvidia-sync exec -- bash ~/dgx-toolbox/setup/dgx-global-base-setup.sh
   ```

4. Build all toolbox images:
   ```bash
   nvidia-sync exec -- bash ~/dgx-toolbox/build-toolboxes.sh
   ```

5. Enable Ollama remote access:
   ```bash
   nvidia-sync exec -- bash ~/dgx-toolbox/inference/setup-ollama-remote.sh
   ```

### Launching Tools Remotely

For **background services**, launch with `nvidia-sync exec` and then forward the port:

```bash
# Open-WebUI
nvidia-sync exec -- bash ~/dgx-toolbox/inference/start-open-webui-sync.sh
nvidia-sync forward 12000

# sparkrun workload (model serving)
nvidia-sync exec -- sparkrun run nemotron-3-nano-4b-bf16-vllm --recipe-path ~/dgx-toolbox/recipes
nvidia-sync forward 8000

# sparkrun proxy (OpenAI-compatible on :4000 — same as legacy LiteLLM)
nvidia-sync exec -- sparkrun proxy start
nvidia-sync forward 4000

# Unsloth Studio
nvidia-sync exec -- bash ~/dgx-toolbox/containers/unsloth-studio-sync.sh
nvidia-sync forward 8000

# n8n
nvidia-sync exec -- bash ~/dgx-toolbox/containers/start-n8n.sh &
nvidia-sync forward 5678

# Triton TRT-LLM
nvidia-sync exec -- bash ~/dgx-toolbox/eval/triton-trtllm-sync.sh
nvidia-sync forward 8010

# Label Studio
nvidia-sync exec -- bash ~/dgx-toolbox/data/start-label-studio.sh &
nvidia-sync forward 8081

# Argilla
nvidia-sync exec -- bash ~/dgx-toolbox/data/start-argilla.sh &
nvidia-sync forward 6900

# Safety Harness
nvidia-sync exec -- bash ~/dgx-toolbox/harness/start-harness.sh &
nvidia-sync forward 5000

# HITL Dashboard
nvidia-sync exec -- python -m harness.hitl ui --port 8501 &
nvidia-sync forward 8501
```

For **interactive containers**, use `nvidia-sync exec -it`:

```bash
nvidia-sync exec -it -- bash ~/dgx-toolbox/containers/ngc-pytorch.sh
nvidia-sync exec -it -- bash ~/dgx-toolbox/eval/eval-toolbox.sh
nvidia-sync exec -it -- bash ~/dgx-toolbox/data/data-toolbox.sh
```

For **Jupyter Lab**:

```bash
nvidia-sync exec -- bash ~/dgx-toolbox/containers/ngc-jupyter.sh &
nvidia-sync forward 8888

nvidia-sync exec -- bash ~/dgx-toolbox/eval/eval-toolbox-jupyter.sh &
nvidia-sync forward 8889

nvidia-sync exec -- bash ~/dgx-toolbox/data/data-toolbox-jupyter.sh &
nvidia-sync forward 8890
```

### NVIDIA Sync Custom App Configuration

Register these tools as custom apps in NVIDIA Sync so they appear in the Sync UI. Add one entry per app — Sync supports one port per custom app.

| App Name | Command | Port | Auto-open |
|----------|---------|------|-----------|
| Open-WebUI | `bash ~/dgx-toolbox/inference/start-open-webui-sync.sh` | 12000 | Yes |
| sparkrun proxy | `sparkrun proxy start` | 4000 | No |
| Unsloth Studio | `bash ~/dgx-toolbox/containers/unsloth-studio-sync.sh` | 8000 | Yes |
| n8n | `bash ~/dgx-toolbox/containers/start-n8n.sh` | 5678 | Yes |
| Label Studio | `bash ~/dgx-toolbox/data/start-label-studio.sh` | 8081 | Yes |
| Argilla | `bash ~/dgx-toolbox/data/start-argilla.sh` | 6900 | Yes |
| Eval Jupyter | `bash ~/dgx-toolbox/eval/eval-toolbox-jupyter.sh` | 8889 | Yes |
| Data Jupyter | `bash ~/dgx-toolbox/data/data-toolbox-jupyter.sh` | 8890 | Yes |
| NGC Jupyter | `bash ~/dgx-toolbox/containers/ngc-jupyter.sh` | 8888 | Yes |
| Triton TRT-LLM | `bash ~/dgx-toolbox/eval/triton-trtllm-sync.sh` | 8010 | No |
| sparkrun workload | `sparkrun run nemotron-3-nano-4b-bf16-vllm --recipe-path ~/dgx-toolbox/recipes` | 8000 | No |
| Autoresearch | `bash ~/dgx-toolbox/karpathy-autoresearch/launch-autoresearch-sync.sh` | -- | No |
| Safety Harness | `bash ~/dgx-toolbox/harness/start-harness.sh` | 5000 | No |
| HITL Dashboard | `python -m harness.hitl ui --port 8501` | 8501 | Yes |
| Model Store | `bash ~/dgx-toolbox/modelstore.sh status` | -- | No |

Refer to the [NVIDIA Sync custom apps documentation](https://docs.nvidia.com/dgx/dgx-spark/nvidia-sync.html#spark-nvidia-sync) for the exact configuration format.

**Note:** When launching a custom app for the first time, Sync may auto-open a browser window before the service is ready — you'll see a "localhost refused to connect" or similar error. This is normal. Many containers install dependencies on first launch (Unsloth Studio can take up to 30 minutes). Wait a few minutes and refresh the page.

### Port Forwarding Summary

```bash
nvidia-sync forward 4000    # sparkrun proxy (LiteLLM)
nvidia-sync forward 5000    # Safety Harness
nvidia-sync forward 5678    # n8n
nvidia-sync forward 6900    # Argilla
nvidia-sync forward 8000    # Unsloth Studio OR sparkrun workload (vLLM)
nvidia-sync forward 8010    # Triton TRT-LLM (HTTP)
nvidia-sync forward 8011    # Triton TRT-LLM (gRPC)
nvidia-sync forward 8021    # sparkrun eval-checkpoint (when running)
nvidia-sync forward 8080    # code-server
nvidia-sync forward 8081    # Label Studio
nvidia-sync forward 8501    # HITL Dashboard
nvidia-sync forward 8888    # Jupyter Lab (NGC)
nvidia-sync forward 8889    # Jupyter Lab (Eval Toolbox)
nvidia-sync forward 8890    # Jupyter Lab (Data Toolbox)
nvidia-sync forward 11434   # Ollama
nvidia-sync forward 12000   # Open-WebUI
```

## Suggested Aliases

See `example.bash_aliases` for the complete set. Install with:

```bash
cp ~/dgx-toolbox/example.bash_aliases ~/.bash_aliases && source ~/.bash_aliases
```

Key aliases:

| Alias | Action |
|-------|--------|
| `claude-ollama` | Use local Ollama models with Claude Code |
| `claude-ollama-danger` | Claude Code with Ollama + skip permissions |
| `claude-litellm` | Route Claude Code through sparkrun proxy (LiteLLM, `:4000`) |
| `claude-litellm-danger` | Claude Code via sparkrun proxy + skip permissions |
| `claude-danger` | Native Claude Code + skip permissions |
| `build-all` | Build base → eval → data toolbox images |
| `dgx-status` | Show all services, images, and disk usage |
| `inference-up` / `inference-down` | Start/stop inference stack (Open-WebUI + sparkrun proxy) |
| `data-stack-up` / `data-stack-down` | Start/stop data stack (Label Studio + Argilla) |
| `vllm` / `vllm-stop` / `vllm-status` / `vllm-logs` | Run / stop / inspect a sparkrun model workload |
| `litellm` / `litellm-stop` / `litellm-status` | Start / stop / inspect the sparkrun OpenAI-compatible proxy |
| `litellm-models` / `litellm-alias` | Refresh proxy routing table / manage model aliases |
| `dgx-mode` | Switch between single- and multi-node sparkrun modes |
| `dgx-recipes` | Register / list / update sparkrun recipe registries (official + community) |
| `eval-toolbox` / `data-toolbox` | Interactive toolbox shells |
| `harness` / `harness-stop` | Start/stop safety harness gateway |
| `hitl` | Launch HITL review dashboard |
| `docker-stop-all` | Stop all running containers |

## Using DGX Toolbox from External Projects

The `examples/` directory contains drop-in files for integrating DGX Toolbox into your own projects:

| File | Purpose |
|------|---------|
| `examples/dgx_toolbox.py` | Python execution engine — resolves config, validates preconditions, launches containers, executes commands |
| `examples/dgx_toolbox.yaml` | Sample YAML config — maps component names to container scripts, workdirs, pinned deps, and validation paths |

```bash
# Copy into your project
cp ~/dgx-toolbox/examples/dgx_toolbox.py  your-project/scripts/dgx_toolbox.py
cp ~/dgx-toolbox/examples/dgx_toolbox.yaml your-project/config/dgx_toolbox.yaml

# Use from Python
from scripts.dgx_toolbox import get_toolbox

dgx = get_toolbox()
dgx.ensure_ready("training")
dgx.execute("training", "python", "train.py")
```

Edit the YAML to point at your container names, workdirs, and validation paths. The `dgx_toolbox_path` setting (or `DGX_TOOLBOX_PATH` env var) tells the engine where your dgx-toolbox clone lives.

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

## Third-Party Software

This repository vendors [sparkrun](https://github.com/spark-arena/sparkrun) as a git submodule at `vendor/sparkrun`. sparkrun is distributed under the Apache License 2.0. See `NOTICE` in the repo root for attribution and `vendor/sparkrun/LICENSE` for the full upstream licence text. The pinned commit is recorded in `.sparkrun-pin`.

## License

This project is licensed under the MIT License — see [`LICENSE`](./LICENSE).

By including sparkrun as a submodule, any redistribution of the combined work must also comply with the terms of the Apache License 2.0 for the files under `vendor/sparkrun/`. sparkrun's source is not relicensed — it is sublicensed to downstream users under its original Apache-2.0 terms as permitted by Section 4 of that licence. See `NOTICE` for details.
