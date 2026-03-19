# Changelog

## 2026-03-19 — Data Engineering Toolbox

### Added

- **data-toolbox/Dockerfile** — NGC PyTorch base + data engineering stack (DuckDB, datatrove, datasketch, distilabel, Faker, cleanlab, great-expectations, trafilatura, resiliparse, pdfplumber, etc.)
- **data-toolbox-build.sh** — Build the data-toolbox Docker image
- **data-toolbox.sh** — Interactive data processing container with GPU access and host mounts (`~/data/`)
- **data-toolbox-jupyter.sh** — Jupyter Lab on data-toolbox image (port 8890)
- **start-label-studio.sh** — Label Studio in Docker with persistent storage (port 8081)
- **start-argilla.sh** — Argilla in Docker with persistent storage (port 6900)

## 2026-03-19 — Eval Toolbox & Triton TRT-LLM

### Added

- **eval-toolbox/Dockerfile** — NGC PyTorch base + Python-level eval stack (lm-eval, ragas, torchmetrics, pycocotools, wandb, mlflow, tritonclient, etc.)
- **eval-toolbox-build.sh** — Build the eval-toolbox Docker image
- **eval-toolbox.sh** — Interactive eval container with GPU access and host mounts (`~/eval/`)
- **eval-toolbox-jupyter.sh** — Jupyter Lab on eval-toolbox image (port 8889)
- **triton-trtllm.sh** — Triton Inference Server + TensorRT-LLM backend (ports 8010-8012)
- **triton-trtllm-sync.sh** — Triton launcher optimized for NVIDIA Sync (background, no TTY)

## 2026-03-19 — Initial release

### Scripts

- **dgx-global-base-setup.sh** — Idempotent DGX environment setup (build tools, Miniconda, pyenv)
- **ngc-pytorch.sh** — Interactive NGC PyTorch container with GPU access
- **ngc-jupyter.sh** — Jupyter Lab on NGC PyTorch container (port 8888)
- **ngc-quickstart.sh** — In-container guide showing available ML packages and workflows
- **unsloth-studio.sh** — Unsloth Studio launcher with browser auto-open and readiness polling
- **unsloth-studio-sync.sh** — Unsloth Studio launcher optimized for NVIDIA Sync (background, no TTY)
- **start-n8n.sh** — n8n workflow automation via Docker (port 5678)
