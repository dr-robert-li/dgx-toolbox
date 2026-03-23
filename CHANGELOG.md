# Changelog

## 2026-03-24 — Safety Harness Fixes & Polish

### Fixed

- **Replay eval rate limiting** — TPM boundary off-by-one (`>` → `>=`), retry backoff too short for 60s sliding window, transport errors (429/404/502/503/timeout) now retried with exponential backoff [2s, 4s, 8s, 16s, 65s]
- **Replay eval error handling** — Transport errors no longer misclassified as "allow"; new `error_cases` counter excludes them from F1/precision/recall; CLI prints warning when errors > 0
- **Replay eval timeout** — Increased httpx timeout from 60s to 180s for shared-GPU inference; `ReadTimeout` caught and retried instead of crashing
- **Default model** — Changed default from `llama3.1` to `nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16` (matches DGX Spark vLLM config)
- **vLLM compose** — Added `--trust-remote-code` and configurable `--gpu-memory-utilization` (default 0.5) for coexistence with other GPU workloads
- **Dev-team rate limits** — Increased from 60 RPM / 100K TPM to 600 RPM / 1M TPM for eval replay runs
- **Dev-team allowed models** — Changed from restricted list to wildcard (`"*"`)

### Changed

- **gradio and asciichartpy** moved from optional to core dependencies — installed by default with `pip install -e .`
- **Default Nemotron model** — Updated across docker-compose, README, LiteLLM config, vllm-model to `nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16`
- **.gitignore** — Fixed path from `safety-harness/` to `harness/`, added trace DB and pending dataset ignores
- **example.bash_aliases** — Added `harness`, `harness-stop`, `hitl` aliases

## 2026-03-23 — Safety Harness (v1.1)

### Added (Safety Harness)

- **harness/** — FastAPI safety gateway on :5000 that proxies to LiteLLM with full request/response screening
- **Multi-tenant auth** — API key verification (argon2), per-tenant rate limiting (RPM + TPM sliding window), bypass flags
- **Input guardrails** — Unicode NFC/NFKC normalization + zero-width stripping + homoglyph detection, NeMo Guardrails content filtering, Presidio PII/secrets detection, prompt injection detection (regex heuristics + NeMo LLM-as-judge)
- **Output guardrails** — Toxicity scanning, jailbreak-success detection, output PII redaction via NeMo output rails
- **3 refusal modes** — Hard block (principled refusal), soft steer (LLM-rewrites flagged prompts), informative (explains policy + suggests alternatives). Configurable per-rail
- **Constitutional AI critique** — Single-pass critique-revise loop for high-risk outputs against user-editable `constitution.yaml` with 12 default principles across 4 categories. Configurable judge model (default = same model). AI-guided tuning suggestions via `POST /admin/suggest-tuning` and `python -m harness.critique analyze`
- **PII-safe trace store** — Every request/response logged to SQLite (WAL mode) with PII redacted before write. Guardrail decisions, CAI critique, and refusal events recorded per trace. Query by request_id or time range
- **Eval harness** — Replay safety/refusal datasets (40-case starter included) with F1/CRR/FRR + P50/P95 latency scoring. lm-eval integration via custom HarnessLM class (generative through gateway, loglikelihood direct to LiteLLM). Unified eval_runs SQLite storage with ASCII trend charts and JSON export
- **CI regression gate** — `python -m harness.eval gate --tolerance 0.02` checks safety + capability + latency metrics against previous run or pinned baseline. Exit 0=pass, 1=regression, 2=error
- **Red teaming** — garak one-shot vulnerability scans via subprocess wrapper with 3 preset profiles (quick/standard/thorough). Adversarial prompt generation from near-miss traces via judge model. Async job dispatch (asyncio + SQLite, one-at-a-time semaphore). Dataset balance enforcement with configurable max category ratio
- **HITL dashboard** — Gradio review UI (`python -m harness.hitl ui --port 8501`) with priority-sorted queue (closest-to-threshold first), side-by-side diff view, approve/reject/edit corrections. Headless API mode (same endpoints, no Gradio required). Threshold calibration from corrections (`python -m harness.hitl calibrate`). OpenAI-format JSONL fine-tuning export
- **NeMo Guardrails aarch64 validated** — `pip install nemoguardrails` + Annoy C++ build + Presidio + spaCy confirmed working on DGX Spark aarch64
- Added `harness`, `harness-stop`, and `hitl` aliases to `example.bash_aliases`
- Updated `.gitignore` for harness runtime artifacts
- Updated README with Safety Harness section, architecture diagram, API reference, and CLI tools

## 2026-03-22 — Autonomous Research + Model Store

### Added (Autonomous Research)

- **karpathy-autoresearch/launch-autoresearch.sh** — Interactive launcher: clone/pull latest master, 5-option data source menu (default/local/HuggingFace/GitHub/Kaggle), DGX Spark tuning, optional test run
- **karpathy-autoresearch/launch-autoresearch-sync.sh** — Headless NVIDIA Sync variant using env vars (AUTORESEARCH_DATA_SOURCE, AUTORESEARCH_DATA_PATH)
- **karpathy-autoresearch/spark-config.sh** — GPU tuning overrides for Blackwell GB10 (6,144 CUDA cores, 192 Tensor Cores, 128 GB unified LPDDR5x)
- **karpathy-autoresearch/README.md** — Tuning rationale, data source examples, interactive/headless usage guide
- Added `autoresearch` and `autoresearch-stop` aliases to example.bash_aliases

### Added (Model Store)

- **modelstore.sh** -- Tiered model storage CLI (init, status, migrate, recall, revert)
- **modelstore/cmd/status.sh** -- Dashboard showing all models by tier with sizes, last-used timestamps, drive totals, watcher/cron status
- **modelstore/cmd/revert.sh** -- Interrupt-safe full revert with preview, --force flag, cleanup of cron/watcher/cold dirs
- **modelstore/cmd/migrate.sh** -- Automated hot-to-cold migration with dry-run, stale detection, flock concurrency guard
- **modelstore/cmd/recall.sh** -- Cold-to-hot recall with usage timestamp reset, auto-trigger from watcher
- **modelstore/cmd/init.sh** -- Interactive setup wizard with filesystem validation, model scan, cron install
- Tiered storage automation via cron (migrate stale models, disk space alerts)
- Usage tracking via docker events + inotifywait watcher daemon
- HuggingFace and Ollama storage adapters with safety guards

### Changed

- Reorganized project root into subdirectories: inference/, data/, eval/, containers/, setup/
- Updated example.bash_aliases with new script paths and modelstore alias

## 2026-03-20 — Optimization & Orchestration

### Added

- **base-toolbox/Dockerfile** — Shared base image (NGC PyTorch + common packages: pandas, pyarrow, datasets, openai, scikit-learn, typer, rich); eval and data toolboxes now build on top
- **build-toolboxes.sh** — Single command to build all three images in order (alias: `build-all`)
- **lib.sh** — Shared function library for launcher scripts (`get_ip`, `is_running`, `ensure_container`, `print_banner`, `stream_logs`, `sync_exit`)
- **docker-compose.inference.yml** — Compose stack for Open-WebUI + LiteLLM + vLLM (aliases: `inference-up`, `inference-down`)
- **docker-compose.data.yml** — Compose stack for Label Studio + Argilla (aliases: `data-stack-up`, `data-stack-down`)
- **status.sh** — Service status, image sizes, and disk usage dashboard (alias: `dgx-status`)

### Changed

- **eval-toolbox/Dockerfile** — Now `FROM base-toolbox:latest` (shared layer with data-toolbox)
- **data-toolbox/Dockerfile** — Now `FROM base-toolbox:latest` (shared layer with eval-toolbox)
- **eval-toolbox-build.sh** / **data-toolbox-build.sh** — Auto-build base image if missing
- Refactored launcher scripts to use `lib.sh`: `start-n8n.sh`, `start-label-studio.sh`, `start-argilla.sh`, `start-open-webui.sh`, `start-open-webui-sync.sh`

## 2026-03-19 — Cross-Tool Integrations

### Added

- **setup-litellm-config.sh** — Interactive LiteLLM config generator (auto-detects Ollama models and vLLM, prompts for OpenAI/Anthropic/Gemini API keys)
- **example.vllm-model** — Default model config for vLLM (`nvidia/Llama-3.1-Nemotron-Nano-8B-v1`)

### Changed

- **eval-toolbox** — Added `openai` package, `host.docker.internal` networking, cross-mount of `~/data/exports` (read-only)
- **data-toolbox** — Added `openai` package, `host.docker.internal` networking, cross-mount of `~/eval/models` (read-only)
- **vLLM scripts** — Read default model from `~/.vllm-model` when no argument passed

## 2026-03-19 — Inference Playground

### Added

- **start-open-webui.sh** — Open-WebUI chat interface with bundled Ollama (port 12000)
- **start-open-webui-sync.sh** — Open-WebUI launcher optimized for NVIDIA Sync
- **start-vllm.sh** — vLLM OpenAI-compatible inference server (port 8020)
- **start-vllm-sync.sh** — vLLM launcher optimized for NVIDIA Sync
- **start-litellm.sh** — LiteLLM unified API proxy for Ollama/vLLM/cloud APIs (port 4000)
- **start-litellm-sync.sh** — LiteLLM launcher optimized for NVIDIA Sync
- **setup-ollama-remote.sh** — Reconfigure Ollama systemd to listen on all interfaces

## 2026-03-19 — Data Engineering Toolbox

### Added

- **data-toolbox/Dockerfile** — NGC PyTorch base + data engineering stack (DuckDB, datatrove, datasketch, distilabel, Faker, cleanlab, trafilatura, pdfplumber, etc.)
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
