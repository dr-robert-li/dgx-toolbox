# Codebase Structure

**Analysis Date:** 2026-04-01

## Directory Layout

```
dgx-toolbox/
├── base-toolbox/               # Base Docker image (NGC PyTorch + common deps)
│   └── Dockerfile
├── containers/                 # GPU container launchers (Unsloth, NGC, n8n)
│   ├── unsloth-studio.sh
│   ├── unsloth-studio-sync.sh
│   ├── unsloth-headless.sh
│   ├── unsloth-headless-sync.sh
│   ├── ngc-pytorch.sh
│   ├── ngc-jupyter.sh
│   ├── ngc-quickstart.sh
│   └── start-n8n.sh
├── data/                       # Data engineering launchers
│   ├── data-toolbox.sh
│   ├── data-toolbox-build.sh
│   ├── data-toolbox-jupyter.sh
│   ├── start-label-studio.sh
│   └── start-argilla.sh
├── data-toolbox/               # Data toolbox Docker image
│   └── Dockerfile
├── eval/                       # Evaluation launchers
│   ├── eval-toolbox.sh
│   ├── eval-toolbox-build.sh
│   ├── eval-toolbox-jupyter.sh
│   ├── triton-trtllm.sh
│   └── triton-trtllm-sync.sh
├── eval-toolbox/               # Eval toolbox Docker image
│   └── Dockerfile
├── examples/                   # Programmatic Python interface
│   └── dgx_toolbox.py
├── harness/                    # Safety Harness (Python/FastAPI)
│   ├── main.py                 # App factory + lifespan
│   ├── start-harness.sh        # Launcher script
│   ├── auth/                   # Bearer token auth
│   │   ├── __init__.py
│   │   └── bearer.py
│   ├── config/                 # Tenant + rail config loading
│   │   ├── __init__.py
│   │   ├── loader.py           # TenantConfig Pydantic model
│   │   ├── rail_loader.py      # RailConfig loading
│   │   └── rails/              # NeMo rails YAML configs
│   │       └── config.yml
│   ├── critique/               # Constitutional AI engine
│   │   ├── __init__.py
│   │   ├── __main__.py
│   │   ├── analyzer.py         # Trace analysis for tuning suggestions
│   │   ├── constitution.py     # Constitution YAML loading
│   │   └── engine.py           # CritiqueEngine
│   ├── data/                   # Runtime data (traces.db, garak runs)
│   │   └── garak-runs/
│   ├── eval/                   # Eval framework within harness
│   │   ├── __init__.py
│   │   ├── __main__.py
│   │   ├── datasets/           # Eval datasets
│   │   │   └── pending/        # Pending red team variants
│   │   ├── gate.py             # Eval gate (pass/fail)
│   │   ├── lm_model.py         # HarnessLM for lm-eval
│   │   ├── metrics.py          # Metric computation
│   │   ├── replay.py           # Trace replay evaluation
│   │   ├── runner.py           # lm-eval wrapper
│   │   └── trends.py           # Eval trend analysis
│   ├── guards/                 # Guardrail engine
│   │   ├── __init__.py
│   │   ├── engine.py           # GuardrailEngine
│   │   ├── nemo_compat.py      # NeMo compatibility
│   │   ├── normalizer.py       # Unicode normalization
│   │   └── types.py            # GuardrailDecision, RailResult
│   ├── hitl/                   # Human-in-the-loop review
│   │   ├── __init__.py
│   │   ├── __main__.py
│   │   ├── calibrate.py        # Threshold calibration
│   │   ├── export.py           # Data export
│   │   ├── router.py           # HITL API routes
│   │   └── ui.py               # HITL dashboard UI
│   ├── pii/                    # PII redaction
│   │   ├── __init__.py
│   │   └── redactor.py         # spaCy NER redactor
│   ├── proxy/                  # API proxy routes
│   │   ├── __init__.py
│   │   ├── admin.py            # Admin endpoints
│   │   └── litellm.py          # Main chat completions proxy
│   ├── ratelimit/              # Rate limiting
│   │   ├── __init__.py
│   │   └── sliding_window.py   # In-memory sliding window
│   ├── redteam/                # Red team testing
│   │   ├── __init__.py
│   │   ├── __main__.py
│   │   ├── balance.py          # Test suite balance scoring
│   │   ├── engine.py           # Deepteam adversarial generation
│   │   ├── garak_runner.py     # Garak integration
│   │   └── router.py           # Red team API routes
│   ├── scripts/                # Harness utility scripts
│   │   └── validate_aarch64.sh
│   ├── tests/                  # Pytest test suite
│   │   ├── __init__.py
│   │   ├── conftest.py
│   │   ├── test_auth.py
│   │   ├── test_constitution.py
│   │   ├── test_critique.py
│   │   ├── test_eval_gate.py
│   │   ├── test_eval_lm_model.py
│   │   ├── test_eval_replay.py
│   │   ├── test_eval_store.py
│   │   ├── test_eval_trends.py
│   │   ├── test_guardrails.py
│   │   ├── test_hitl.py
│   │   ├── test_nemo_compat.py
│   │   ├── test_normalizer.py
│   │   ├── test_pii.py
│   │   ├── test_proxy.py
│   │   ├── test_rail_config.py
│   │   ├── test_ratelimit.py
│   │   ├── test_redteam.py
│   │   ├── test_redteam_data.py
│   │   └── test_traces.py
│   └── traces/                 # Trace storage
│       ├── __init__.py
│       └── store.py            # TraceStore (async SQLite)
├── inference/                  # Inference server launchers
│   ├── start-vllm.sh
│   ├── start-vllm-sync.sh
│   ├── start-litellm.sh
│   ├── start-litellm-sync.sh
│   ├── start-open-webui.sh
│   ├── start-open-webui-sync.sh
│   ├── setup-litellm-config.sh
│   └── setup-ollama-remote.sh
├── karpathy-autoresearch/      # Autoresearch integration
│   ├── launch-autoresearch.sh
│   ├── launch-autoresearch-sync.sh
│   └── spark-config.sh         # DGX Spark GPU tuning
├── modelstore/                 # Tiered model storage CLI
│   ├── cmd/                    # Subcommands
│   │   ├── init.sh
│   │   ├── migrate.sh
│   │   ├── recall.sh
│   │   ├── revert.sh
│   │   └── status.sh
│   ├── cron/                   # Cron jobs
│   │   ├── disk_check_cron.sh
│   │   └── migrate_cron.sh
│   ├── hooks/                  # Event hooks
│   │   └── watcher.sh
│   ├── lib/                    # Shared libraries
│   │   ├── audit.sh
│   │   ├── common.sh
│   │   ├── config.sh
│   │   ├── hf_adapter.sh
│   │   ├── notify.sh
│   │   └── ollama_adapter.sh
│   └── test/                   # Bash test suite
│       ├── run-all.sh
│       ├── fixtures/
│       ├── smoke.sh
│       ├── test-audit.sh
│       ├── test-common.sh
│       ├── test-config.sh
│       ├── test-disk-check.sh
│       ├── test-fs-validation.sh
│       ├── test-hf-adapter.sh
│       ├── test-init.sh
│       ├── test-migrate.sh
│       ├── test-ollama-adapter.sh
│       ├── test-recall.sh
│       ├── test-revert.sh
│       ├── test-status.sh
│       └── test-watcher.sh
├── scripts/                    # Utility and demo scripts
│   ├── _litellm_register.py    # LiteLLM config helper
│   ├── autoresearch-deregister.sh
│   ├── demo-autoresearch.sh
│   ├── eval-checkpoint.sh
│   ├── screen-data.sh
│   ├── test-data-integration.sh
│   └── test-eval-register.sh
├── setup/                      # System provisioning
│   └── dgx-global-base-setup.sh
├── .github/
│   └── workflows/
│       └── test.yml            # CI pipeline
├── .planning/
│   └── codebase/               # GSD architecture docs
├── build-toolboxes.sh          # Build all Docker images
├── docker-compose.data.yml     # Data stack compose
├── docker-compose.inference.yml # Inference stack compose
├── example.bash_aliases        # Shell aliases template
├── example.vllm-model          # vLLM model config template
├── lib.sh                      # Shared shell library
├── modelstore.sh               # ModelStore CLI router
├── status.sh                   # Service status dashboard
├── CHANGELOG.md                # Version history
├── README.md                   # Main documentation
└── .gitignore                  # Git exclusions
```

## Directory Purposes

**`base-toolbox/`:**
- Purpose: Base Docker image build context (NGC PyTorch + common Python deps)
- Contains: Single `Dockerfile` inheriting from `nvcr.io/nvidia/pytorch:26.02-py3`
- Key deps: datasets, pandas, pyarrow, scikit-learn, openai, huggingface_hub, typer, rich

**`containers/`:**
- Purpose: Specialized GPU container launchers
- Contains: Unsloth Studio (fine-tuning UI), Unsloth headless (autonomous training), NGC PyTorch (interactive), NGC Jupyter, n8n (workflow automation)
- Pattern: Each script manages its own Docker container lifecycle with `source ../lib.sh`

**`data/`:**
- Purpose: Data engineering service launchers
- Contains: data-toolbox (interactive + Jupyter), Label Studio, Argilla launchers
- Pattern: Build scripts (`*-build.sh`) and launch scripts (`*.sh`) are co-located

**`data-toolbox/`:**
- Purpose: Docker image for data processing (inherits from `base-toolbox`)
- Contains: Dockerfile with polars, DuckDB, datatrove, distilabel, cleanlab, cloud storage clients, document extraction tools

**`eval/`:**
- Purpose: Evaluation service launchers
- Contains: eval-toolbox (interactive + Jupyter), Triton TRT-LLM server launchers

**`eval-toolbox/`:**
- Purpose: Docker image for evaluation (inherits from `base-toolbox`)
- Contains: Dockerfile with evaluate, torchmetrics, mlflow, lm-eval, ragas, tritonclient

**`examples/`:**
- Purpose: Programmatic Python interface for external projects to use dgx-toolbox
- Contains: `dgx_toolbox.py` -- DGXToolbox class with validation, container lifecycle, execution engine

**`harness/`:**
- Purpose: Safety Harness FastAPI application -- the most complex subsystem
- Contains: 12 Python submodules covering auth, config, critique, eval, guards, hitl, pii, proxy, ratelimit, redteam, traces
- Key files: `main.py` (app factory), `proxy/litellm.py` (main proxy logic), `guards/engine.py` (guardrail engine)
- Tests: `harness/tests/` with 21 test files

**`inference/`:**
- Purpose: LLM inference server launchers
- Contains: vLLM, LiteLLM, Open-WebUI launchers + config generators + Ollama remote setup

**`karpathy-autoresearch/`:**
- Purpose: Integration with karpathy/autoresearch for autonomous ML experiments
- Contains: Launch scripts + DGX Spark GPU config tuning (`spark-config.sh`)

**`modelstore/`:**
- Purpose: Tiered model storage management (hot/cold)
- Contains: CLI subcommands (`cmd/`), shared libraries (`lib/`), cron jobs (`cron/`), hooks (`hooks/`), tests (`test/`)
- Architecture: CLI router in `modelstore.sh` dispatches to `modelstore/cmd/*.sh`

**`scripts/`:**
- Purpose: Utility scripts, integration tests, demos
- Contains: LiteLLM registration helper, autoresearch demo, eval checkpoint scripts

**`setup/`:**
- Purpose: One-time host provisioning
- Contains: `dgx-global-base-setup.sh` (apt packages, Miniconda, pyenv, harness pip install, bash aliases)

## Key File Locations

**Entry Points:**
- `lib.sh`: Shared bash library sourced by all launchers
- `modelstore.sh`: CLI router for model store commands
- `status.sh`: Service status dashboard
- `build-toolboxes.sh`: Build all Docker images (base -> eval + data)
- `harness/main.py`: FastAPI app factory
- `harness/start-harness.sh`: Uvicorn launcher
- `examples/dgx_toolbox.py`: Programmatic Python interface

**Configuration:**
- `docker-compose.inference.yml`: Inference stack (Open-WebUI + LiteLLM + vLLM)
- `docker-compose.data.yml`: Data stack (Label Studio + Argilla)
- `harness/config/rails/config.yml`: NeMo guardrails configuration
- `example.bash_aliases`: Shell aliases template (68 aliases)
- `example.vllm-model`: Default vLLM model template
- `.github/workflows/test.yml`: CI pipeline (shellcheck, pytest, syntax, secrets, vulns)

**Core Logic:**
- `harness/proxy/litellm.py`: Main proxy route with 8-step pipeline (auth -> rate limit -> guardrails -> proxy -> output rails -> critique -> PII -> trace)
- `harness/guards/engine.py`: GuardrailEngine with input/output rails, three refusal modes
- `harness/critique/engine.py`: CritiqueEngine for Constitutional AI critique-revise loop
- `harness/traces/store.py`: TraceStore async SQLite with traces, eval_runs, redteam_jobs, corrections
- `harness/config/loader.py`: TenantConfig Pydantic model
- `harness/auth/bearer.py`: Argon2 bearer token verification
- `harness/redteam/engine.py`: Deepteam adversarial prompt generation
- `modelstore/cmd/migrate.sh`: Hot-to-cold model migration with interrupt safety
- `modelstore/lib/common.sh`: Mount verification, space checks, filesystem validation

**Testing:**
- `harness/tests/`: 21 pytest test files for Safety Harness
- `modelstore/test/`: 16 bash test files for ModelStore
- `modelstore/test/run-all.sh`: ModelStore test runner
- `harness/tests/conftest.py`: Shared pytest fixtures

## Naming Conventions

**Files:**
- Launcher scripts: `start-{service}.sh` (e.g., `start-vllm.sh`, `start-label-studio.sh`)
- Build scripts: `{toolbox}-build.sh` (e.g., `data-toolbox-build.sh`)
- Toolbox shells: `{toolbox}.sh` (e.g., `data-toolbox.sh`)
- Jupyter launchers: `{toolbox}-jupyter.sh` (e.g., `data-toolbox-jupyter.sh`)
- Sync variants: `{script}-sync.sh` (e.g., `start-vllm-sync.sh`)
- Config generators: `setup-{service}-config.sh` or `setup-{service}.sh`
- Example configs: `example.{name}` (e.g., `example.bash_aliases`)
- Python modules: `snake_case.py` (e.g., `sliding_window.py`, `rail_loader.py`)
- Test files (Python): `test_{module}.py` (e.g., `test_proxy.py`)
- Test files (Bash): `test-{module}.sh` (e.g., `test-config.sh`)

**Directories:**
- Docker images: `{name}-toolbox/` (e.g., `base-toolbox/`, `data-toolbox/`)
- Service groups: `{domain}/` (e.g., `inference/`, `data/`, `eval/`, `containers/`)
- Python packages: `{name}/` with `__init__.py` (e.g., `harness/auth/`, `harness/guards/`)
- CLI subcommands: `cmd/` (in `modelstore/`)
- Shared libraries: `lib/` (in `modelstore/`)

## Where to Add New Code

**New Inference Backend:**
- Launcher script: `inference/start-{backend}.sh` following pattern in `inference/start-vllm.sh`
- Sync variant: `inference/start-{backend}-sync.sh`
- Integration: Add to `inference/setup-litellm-config.sh` for auto-detection
- Status: Add `check_service` line to `status.sh`
- Aliases: Add to `example.bash_aliases`
- Docker compose: Add service to `docker-compose.inference.yml`

**New Harness Module:**
- Create directory: `harness/{module}/` with `__init__.py`
- Router: Add `{module}/router.py` with APIRouter, include in `harness/main.py`
- Tests: Add `harness/tests/test_{module}.py`
- Follow existing pattern: see `harness/hitl/router.py` for router pattern, `harness/redteam/engine.py` for engine pattern

**New Harness Guardrail:**
- Add rail name to `harness/guards/engine.py` `_input_rails` or `_output_rails` list
- Add rail config entry to `harness/config/rails/rails.yaml`
- Add suggestion text to `_RAIL_SUGGESTIONS` dict in `harness/guards/engine.py`
- Add test in `harness/tests/test_guardrails.py`

**New ModelStore Subcommand:**
- Create: `modelstore/cmd/{command}.sh`
- Source: `${SCRIPT_DIR}/../lib/common.sh` and `${SCRIPT_DIR}/../lib/config.sh`
- Register: Add `case` entry in `modelstore.sh`
- Test: Create `modelstore/test/test-{command}.sh`

**New Container/Toolbox:**
- Dockerfile: Create `{name}-toolbox/Dockerfile` inheriting from `base-toolbox:latest`
- Build: Add to `build-toolboxes.sh`
- Launcher: Create `{domain}/{name}-toolbox.sh` following `data/data-toolbox.sh` pattern
- Jupyter: Optionally add `{domain}/{name}-toolbox-jupyter.sh`

**New Utility Script:**
- Location: `scripts/{name}.sh` or `scripts/{name}.py`
- Pattern: See `scripts/_litellm_register.py` for Python utilities, `scripts/demo-autoresearch.sh` for bash demos

**New Data Labeling Platform:**
- Launcher: `data/start-{platform}.sh` following `data/start-label-studio.sh` pattern
- Docker compose: Add to `docker-compose.data.yml`
- Status: Add to `status.sh`
- Aliases: Add to `example.bash_aliases`

## Special Directories

**`harness/data/`:**
- Purpose: Runtime data for Safety Harness (SQLite traces.db, garak run outputs)
- Generated: Yes (at runtime)
- Committed: Directory structure only (data files gitignored)

**`harness/eval/datasets/pending/`:**
- Purpose: Pending red team adversarial variants awaiting human review
- Generated: Yes (by deepteam engine)
- Committed: No (generated at runtime)

**`modelstore/test/fixtures/`:**
- Purpose: Test data for ModelStore bash tests
- Generated: No (committed)
- Committed: Yes

**`.planning/codebase/`:**
- Purpose: GSD-generated architecture documentation
- Generated: Yes (by `/gsd:map-codebase`)
- Committed: Yes

**`.github/workflows/`:**
- Purpose: CI pipeline definitions
- Contains: `test.yml` -- shellcheck, harness pytest, bash syntax, secrets scan, vulnerability scan
- Committed: Yes

**Host directories (not in repo):**
- `~/.modelstore/` -- ModelStore config, usage tracking, audit logs
- `~/.litellm/` -- LiteLLM proxy config and env vars
- `~/.cache/huggingface/` -- HuggingFace model/dataset cache
- `~/data/` -- Training data (raw, processed, curated, synthetic, exports)
- `~/eval/` -- Evaluation datasets, models, runs
- `~/unsloth-data/` -- Fine-tuning session data

---

*Structure analysis: 2026-04-01*
