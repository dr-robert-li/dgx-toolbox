# Technology Stack

**Analysis Date:** 2026-03-19

## Languages

**Primary:**
- Python 3.x - Core scripting language for all containerized toolboxes and utilities
- Bash - Shell scripting for system setup and Docker orchestration

**Secondary:**
- YAML - Configuration files for LiteLLM proxy and service configs

## Runtime

**Environment:**
- NVIDIA DGX Spark (aarch64 ARM64 architecture)
- Docker with NVIDIA Container Toolkit (GPU support via `--gpus all`)
- NVIDIA CUDA 12.x (provided by base NGC images)
- PyTorch 2.x (provided by NGC base images)

**Package Manager:**
- pip - Python package management within containers
- conda/Miniconda 3 (aarch64) - Optional user-level package management for system Python
- apt-get - System-level package management on DGX base OS

**Lockfile:** No explicit lockfiles; depends on pinned base image tags

## Frameworks

**Core Inference:**
- vLLM (latest) - High-throughput OpenAI-compatible inference server
- Ollama (systemd service) - Local LLM server with model management
- LiteLLM (main-latest) - Unified OpenAI-compatible proxy router
- Open-WebUI (ollama tag) - Chat interface with bundled Ollama and RAG support

**Fine-tuning & Training:**
- Unsloth - Memory-efficient fine-tuning framework (via nvcr.io/nvidia/pytorch)
- distilabel - Synthetic data generation and LLM-powered data pipelines

**Evaluation:**
- lm-eval - Language model evaluation harness
- ragas - RAG evaluation metrics
- evaluate - Hugging Face evaluation library
- torchmetrics - PyTorch-native metrics

**Data Processing:**
- pandas - Tabular data manipulation
- polars - Fast columnar dataframe library
- pyarrow - Arrow format and memory-efficient I/O
- duckdb - SQL queries over files and dataframes (CLI included in data-toolbox)
- datasets (HuggingFace) - Dataset loading and curation

**Serving & Infrastructure:**
- Triton Inference Server (26.02-trtllm) - Multi-backend inference server with TensorRT-LLM
- n8n - Workflow automation platform
- Label Studio - Data labeling interface
- Argilla (quickstart) - Data annotation and active learning
- Jupyter Lab - Interactive development environment

**Testing & Monitoring:**
- wandb - Experiment tracking and model logging
- mlflow - ML model tracking and serving
- tritonclient - Python client for Triton inference

## Key Dependencies

**Critical LLM & Inference:**
- vllm/vllm-openai (latest) - Serves as main inference endpoint for high-throughput workloads
- openai (Python SDK) - API client for cloud models and local endpoints
- berriai/litellm (main-latest) - Routes requests to any backend (local or cloud)

**Data Stack (data-toolbox):**
- datatrove[io,processing,cli,s3] - Large-scale data processing with cloud I/O
- datasketch - Probabilistic deduplication (hashing-based)
- mmh3, xxhash - Fast hashing for deduplication
- ftfy - Unicode text cleaning
- trafilatura - Web scraping and content extraction
- beautifulsoup4, lxml, readability-lxml - HTML/XML parsing
- pdfplumber - PDF text extraction
- python-docx, openpyxl - Office document parsing
- label-studio-sdk, argilla - Client libraries for annotation platforms
- boto3, azure-storage-blob, google-cloud-storage, smart-open[all] - Multi-cloud I/O
- cleanlab - Data quality and label errors detection
- orjson, msgspec, zstandard - Fast serialization and compression

**Evaluation Stack (eval-toolbox):**
- lm-eval - Standardized benchmark evaluation
- ragas - RAG system evaluation metrics
- evaluate - Hugging Face metrics library
- pycocotools - COCO dataset metrics (CV evaluation)
- albumentations - Image augmentation
- scikit-learn - Machine learning utilities
- scipy - Scientific computing
- tritonclient[all] - Triton inference client (HTTP/gRPC)

**Development & CLI:**
- typer[all] - CLI framework with rich integration
- rich - Terminal formatting and progress bars
- tqdm - Progress bars

**System Utilities:**
- DuckDB CLI (v1.2.2, aarch64-specific) - Installed directly in data-toolbox
- csvkit - CSV manipulation tools
- pigz - Parallel gzip compression
- parallel - GNU parallel for batch processing
- pv - Pipe viewer for monitoring
- poppler-utils - PDF utilities
- tesseract-ocr - Optical character recognition
- git, build-essential, libgl1 - Build and system dependencies

## Configuration

**Environment:**
- DEBIAN_FRONTEND=noninteractive - Silent apt installs in containers
- PIP_NO_CACHE_DIR=1 - Minimal layer size in Docker builds
- PYTHONUNBUFFERED=1 - Real-time Python logging
- SCARF_NO_ANALYTICS=true, DO_NOT_TRACK=true, ANONYMIZED_TELEMETRY=false - Privacy settings for Open-WebUI
- NGC_API_KEY - For NGC container registry access (required at setup)
- OPENAI_API_KEY, ANTHROPIC_API_KEY, GEMINI_API_KEY - Cloud API credentials for LiteLLM (stored in `~/.litellm/.env`)

**Build:**
- Dockerfiles in `data-toolbox/Dockerfile` and `eval-toolbox/Dockerfile`
- Base images pinned to NGC PyTorch 26.02-py3 (CUDA 12, PyTorch 2.x)
- Multi-stage builds not used; single-layer pip installs for simplicity

**Base Images:**
- `nvcr.io/nvidia/pytorch:26.02-py3` - NGC PyTorch with CUDA 12 and PyTorch 2.x (data & eval toolboxes)
- `nvcr.io/nvidia/pytorch:25.11-py3` - NGC PyTorch (Unsloth Studio)
- `nvcr.io/nvidia/tritonserver:26.02-trtllm-python-py3` - Triton with TensorRT-LLM backend

## Platform Requirements

**Development:**
- NVIDIA DGX Spark (aarch64 ARM64)
- Docker engine with NVIDIA Container Toolkit
- NGC authentication configured for `nvcr.io`
- Minimum 16GB GPU VRAM for most inference workloads
- System Python 3.x for setup scripts
- systemd (for Ollama service management)

**Production:**
- Same as development (this is a single-node DGX deployment)
- NVIDIA Sync for remote access via corporate network
- Persistent host directories for data, models, and configuration

---

*Stack analysis: 2026-03-19*
