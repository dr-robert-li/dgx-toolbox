# Changelog

## 2026-04-22 — Fix: `vllm-stop` / `vllm-logs` / `vllm-status` / `vllm-show` fail with "No hosts specified"

### Fixed

- **`example.bash_aliases`** — `vllm-stop`, `vllm-logs`, `vllm-status`, and `vllm-show` were bare aliases (`sparkrun stop`, `sparkrun logs`, ...). That skipped the host-injection logic the `vllm()` function uses, so running `vllm-stop` on a single-node install where no default sparkrun cluster is registered yet produced `Error: Must specify TARGET or --all.` (no args) or `Error: No hosts specified.` (`--all`) — sparkrun's `_stop_all()` calls `_resolve_hosts_or_exit()` *before* looking at the target. Converted all four to shell functions that:
  - Inject `--hosts localhost` when `DGX_MODE=single` (env or `~/.config/dgx-toolbox/mode.env`) and the caller hasn't passed `--hosts`, `--hosts-file`, `-H`, `--cluster`, or `--solo` — matching the existing `vllm()` behavior.
  - Default `vllm-stop` to `--all` when the user passes no positional target and no `--all` flag, so the common "I'm done, shut it all down" case is a single command.
  - Forward every user-supplied flag and positional arg verbatim; explicit `--hosts` / `--cluster` / `--solo` still wins and is never duplicated.
  - Use `unalias` guards so re-sourcing over an older install's bare aliases doesn't syntax-error.
- Host injection logic is factored into a single internal `_dgx_host_args` helper so all five wrappers (`vllm`, `vllm-stop`, `vllm-logs`, `vllm-status`, `vllm-show`) share one source of truth — the `vllm()` body was refactored to call the helper instead of inlining host-flag detection, keeping PR #9's autoregister / `--foreground` / `--dry-run` logic intact.

### Added

- **`scripts/test-sparkrun-integration.sh`** — Twenty-three new assertions validated via execution against a PATH-stubbed `sparkrun`: presence of each new wrapper function; removal of the old bare aliases; `vllm-stop` with no args injects `--hosts localhost` and adds `--all`; `vllm-stop --all` doesn't duplicate `--all`; `vllm-stop <target>` injects host but omits `--all`; `vllm-stop --hosts` doesn't duplicate `--hosts`; `vllm-stop --cluster` skips host injection; `vllm-stop` with no `DGX_MODE` still defaults to `--all` but skips injection; `vllm-logs` / `vllm-status` / `vllm-show` all inject and forward correctly; each wrapper is a function (not an alias) after sourcing; re-source safety over pre-existing aliases. 137 → 160 assertions on top of PR #9.
- **`README.md`** — Updated the "DGX mode" section to document that `vllm-stop`/`vllm-logs`/`vllm-status`/`vllm-show` inject `--hosts localhost` the same way `vllm` does, and that bare `vllm-stop` defaults to `--all`.

## 2026-04-22 — Feat: auto-register `vllm` workloads with the LiteLLM proxy

### Added

- **`example.bash_aliases`** — The `vllm()` wrapper now spawns a background watchdog after launching a recipe. The watchdog polls `sparkrun proxy status --json` every 5s (up to 20 min), and once the proxy reports running, issues `sparkrun proxy models --refresh` to register the new endpoint. Prints a single `[vllm] Registered new workload with LiteLLM proxy (:4000)` line on success. Removes the manual `litellm-models` step that users previously had to run before `claude-litellm` could see a freshly-launched model.
- **`setup/dgx-mode.sh`** — `_write_mode()` now writes `DGX_PROXY_AUTOREGISTER=1` to `mode.env` for both `single` and `cluster` modes, and **preserves** a pre-existing `DGX_PROXY_AUTOREGISTER=0` across re-runs so users don't lose their opt-out.
- **`scripts/test-sparkrun-integration.sh`** — Seven new assertions: watchdog success path (calls both `proxy status --json` and `proxy models --refresh`, prints the user-facing line); watchdog does not call `proxy models --refresh` when proxy is stopped; `DGX_PROXY_AUTOREGISTER=0` prevents the watchdog from spawning; `--dry-run` suppresses it; `--foreground` suppresses it; and `dgx-mode single` preserves a pre-existing opt-out. All stubbed via tempfile-based test harness — runs in CI without real sparkrun or LiteLLM.

### Design notes

- Default is **on** — auto-registration is what 95% of `vllm`+`claude-litellm` users want, and the watchdog silently no-ops when the proxy isn't running, so it adds no friction to users who don't use LiteLLM.
- Watchdog runs concurrently with sparkrun's foreground log-follow so there's no change to the user's interactive experience. It backgrounds itself with `&` + `disown` so it survives a Ctrl-C of `sparkrun run`.
- Skipped on `--dry-run` (nothing launched) and `--foreground` (would interleave output with streamed container logs).
- Per-invocation override: `DGX_PROXY_AUTOREGISTER=0 vllm <recipe>`.

## 2026-04-22 — Fix: single-node `vllm` fails with "No hosts specified"

### Fixed

- **`setup/dgx-mode.sh`** — `dgx-mode single` only wrote a local `mode.env` marker and never registered any hosts with sparkrun. Sparkrun's `sparkrun run` resolves hosts *before* loading the recipe and exits with `Error: No hosts specified. Use --hosts or configure defaults.` if it finds none — so every single-node user hit this the moment they ran `vllm <recipe>`, including the simplest cases like `vllm qwen3.6`. `cmd_single` now creates (or updates) a sparkrun cluster named `solo` with `hosts=localhost` and sets it as the default. Idempotent — re-running `dgx-mode single` updates the existing `solo` cluster in place. Validated with a stubbed `sparkrun` binary on the happy path and the re-run path.
- **`example.bash_aliases`** — The `vllm()` wrapper now injects `--hosts localhost` defensively when `DGX_MODE=single` (either exported, or read from `~/.config/dgx-toolbox/mode.env`) and the caller hasn't passed `--hosts`, `--hosts-file`, `--cluster`, or `--solo`. Covers users on installs that pre-date the `dgx-mode` fix above, and avoids any regression in the normal `sparkrun cluster set-default` path. Does NOT inject when `DGX_MODE` is unset (so fresh installs that haven't run the mode picker still surface sparkrun's real error message).

### Added

- **`scripts/test-sparkrun-integration.sh`** — Six new assertions: single-mode injects `--hosts localhost` when no host flag is given; injection is skipped when the caller passes `--hosts`; injection is skipped when the caller passes `--solo`; no injection when `DGX_MODE` is unset; `dgx-mode single` calls `sparkrun cluster create solo --hosts localhost --default`; and `dgx-mode single` writes `DGX_MODE=single` to `mode.env`. The case-match in the wrapper also handles `--hosts-file`, `--hosts=...`, `--cluster`, `--cluster=...`, and `-H`. All stubbed — runs in CI without touching real sparkrun.

## 2026-04-22 — Fix: re-source safety for `vllm()` + `dgx-discover` recipe discovery

### Added

- **`setup/dgx-discover.sh` + `dgx-discover` alias** — New convenience wrapper that answers "what models can I actually pull and serve right now?" without having to memorise sparkrun's underlying flags. Subcommands: `list` (default — local recipes + every registered registry), `local` (only `~/dgx-toolbox/recipes/`), `registries` (registered registry list), `search <query>` (sparkrun search by name/model/description), `show <recipe>` (resolved config + VRAM estimate; prefers local path for in-repo recipes), `update` (refresh registries). Flags like `--runtime vllm`, `--registry <name>`, `--all`, `--json` are forwarded to `sparkrun list` / `sparkrun search`. Bare queries like `dgx-discover qwen` fall through to search, and `dgx-discover --runtime vllm` implies `list`.
- **`scripts/test-sparkrun-integration.sh`** — Four new assertions: `setup/dgx-discover.sh` is executable, its `help` and `local` subcommands run cleanly, and a regression test that sourcing `example.bash_aliases` over a pre-existing `vllm` alias still defines `vllm` as a function (the `syntax error near unexpected token `(`` regression below).

### Fixed

- **`example.bash_aliases`** — Re-sourcing the file in a shell that already has `vllm` defined as an alias (e.g. from an older install where `vllm='sparkrun run --recipe-path ...'`) caused `bash: syntax error near unexpected token `(`` because interactive bash expands aliases before parsing the function definition. Prepended `unalias vllm 2>/dev/null || true` so the old alias is cleared before the new function is defined. Verified by reproducing the error interactively and confirming the fix under `bash -ic`.

## 2026-04-22 — Fix: `vllm` wrapper uses real sparkrun CLI (no `--recipe-path`)

### Fixed

- **`example.bash_aliases`** — The `vllm` alias previously passed `--recipe-path ~/dgx-toolbox/recipes` to `sparkrun run`, but sparkrun's `run` command does not expose that flag. Invoking `vllm <recipe>` failed with `Error: No such option: --recipe-path`. Replaced the alias with a `vllm()` shell function that first checks `~/dgx-toolbox/recipes/<name>.yaml` and passes the full path to `sparkrun run`, falling back to sparkrun's normal name resolution (registered registries + CWD) for anything not found locally. Direct paths (`vllm /path/to/recipe.yaml`) and upstream registry names (`vllm qwen3.6`) both work.
- **`scripts/eval-checkpoint.sh`** — Dropped the broken `--recipe-path "$EVAL_RECIPE_PATH"` argument from the `sparkrun run` invocation. The script now resolves `${EVAL_RECIPE_PATH}/${EVAL_RECIPE}.yaml` to a direct path when the file exists, otherwise passes the recipe reference through unchanged so registered-registry names still resolve. `EVAL_RECIPE_PATH` env var is retained as the lookup directory (default: `<repo>/recipes`).
- **`recipes/README.md`** — Rewrote the usage block to match the real sparkrun CLI (name resolution via registries + CWD, or a direct path), and documented the `vllm` wrapper's local-first behaviour.
- **`README.md`** — Corrected the two `sparkrun run ... --recipe-path ~/dgx-toolbox/recipes` snippets (NVIDIA Sync launcher and Port Reference table) to pass the full recipe path. Clarified in the sparkrun section that sparkrun has no `--recipe-path` flag.
- **`scripts/test-sparkrun-integration.sh`** — Updated the alias assertion from `alias vllm='sparkrun run` to `vllm() {` to match the new function form. All 117/117 assertions still pass.

## 2026-04-22 — Default recipe registries + HF model onboarding + LAN URL

### Added

- **`setup/dgx-recipes.sh` + `dgx-recipes` alias** — Idempotent wrapper for registering the [official](https://github.com/spark-arena/recipe-registry) and [community](https://github.com/spark-arena/community-recipe-registry) Spark Arena recipe registries via `sparkrun registry add <URL>` (which reads each repo's `.sparkrun/registry.yaml` manifest). Subcommands: `add` (default), `list`, `update` (restores missing defaults too), `status`. Safe to re-run — already-registered URLs are skipped with a “skip” message; transient failures report clearly and can be retried.
- **`setup/dgx-global-base-setup.sh`** — Now invokes `setup/dgx-recipes.sh add` immediately after the sparkrun install and PATH export, before the mode picker. Gated on `command -v sparkrun` so setup degrades gracefully if the install step skipped. Failures are reported but non-fatal (the mode picker still runs). **Also installs the Hugging Face CLI as a user-level uv tool (`uv tool install --force --with hf_xet "huggingface_hub[cli]"`) and appends `export HF_XET_HIGH_PERFORMANCE=1` to `~/.bashrc` idempotently**, so the `hf` CLI is available out of the box and every HF download — manual or sparkrun-triggered — uses the fast Xet path by default. The “Next steps” summary now prompts users to run `hf auth login` for gated repos, mirroring the existing Kaggle block.
- **`scripts/test-sparkrun-integration.sh`** — Six new assertions total: `setup/dgx-recipes.sh` references `sparkrun registry`; `example.bash_aliases` defines `dgx-recipes`; the existing `bash -n` sweep now also lints the new script; and `setup/dgx-global-base-setup.sh` contains the `hf` CLI install, the `HF_XET_HIGH_PERFORMANCE=1` export, and the `hf auth login` onboarding hint.

### Changed

- **`README.md`** — Quick Start now prints both `http://localhost:4000/v1` and `http://<LAN_IP>:4000/v1` after `litellm`, calls out that base setup now installs the `hf` CLI + `hf_xet` and exports `HF_XET_HIGH_PERFORMANCE=1` automatically, and adds a Hugging Face login step to the optional post-setup block (alongside the existing Kaggle one). The **Downloading new models from Hugging Face** subsection is rewritten to lead with sparkrun's automatic first-run `snapshot_download()` behaviour, then a short `hf auth login` reminder for gated repos, then straight into `dgx-recipes add` + `vllm <recipe>`. The explicit `hf download` walkthrough and the manual `pip install "huggingface_hub[cli]" hf_xet` / `export HF_XET_HIGH_PERFORMANCE=1` snippets were dropped — both are now handled by the setup script. Custom-recipe authoring remains a short pointer to `recipes/README.md`. Also called out the `sparkrun proxy start --host 127.0.0.1` / `--master-key` hardening options since the default bind is `0.0.0.0` with no auth.
- **`recipes/README.md`** — Replaced the outdated `sparkrun registry add <name> <path> --type local` incantation (that CLI form was removed in the current sparkrun release — registry add now only takes a repo URL + manifest) with a `vllm <recipe>` example that uses the alias's pre-wired `--recipe-path`. Cross-linked `dgx-recipes` for upstream registries.
- **`example.bash_aliases`** — New `dgx-recipes` alias under the existing `dgx-mode` grouping.

## 2026-04-22 — sparkrun Integration (v1.5.0)

### Added

- **sparkrun submodule** — [spark-arena/sparkrun](https://github.com/spark-arena/sparkrun) is now vendored at `vendor/sparkrun` (tracks `main`; pinned commit recorded in `.sparkrun-pin`). Replaces the hand-rolled `start-vllm.sh` / `start-litellm.sh` / `setup-litellm-config.sh` launchers with a maintained, Apache-2.0 CLI that supports single-node and multi-node workloads out of the box.
- **`recipes/` directory** — Project-specific sparkrun recipes: `nemotron-3-nano-4b-bf16-vllm.yaml` (preserves the previous default model + gpu-memory envelope) and `eval-checkpoint.yaml` (ephemeral vLLM workload used by `scripts/eval-checkpoint.sh`). Upstream recipes remain available from `vendor/sparkrun/recipes/`.
- **`setup/dgx-mode.sh` + `setup/dgx-mode-picker.sh`** — Choose single-node or multi-node sparkrun defaults. Picker runs on first `setup/dgx-global-base-setup.sh` invocation; `dgx-mode single|cluster <hosts>|status` switches later. On-the-fly overrides remain available via `--solo`, `--cluster NAME`, and `--hosts h1,h2,…`.
- **`scripts/test-sparkrun-integration.sh`** — Smoke test suite that validates submodule pinning, recipe parseability, rewritten downstream scripts, alias coverage, LICENSE/NOTICE attribution, and workflow submodule handling.
- **`scripts/claude-litellm.sh`** — Wrapper that routes Claude Code through the sparkrun proxy (LiteLLM, `:4000`). Discovers models via `sparkrun proxy models --json`, offers a numbered picker, pins every Claude Code tier (`haiku`/`sonnet`/`opus`/`small-fast`) to the chosen local model to prevent cloud fallback, and restores the shell's Anthropic env vars on exit. Mirrors the behaviour of `scripts/claude-ollama.sh`. New aliases: `claude-litellm`, `claude-litellm-danger`.
- **`.github/workflows/test.yml`** now checks out submodules so CI sees sparkrun.
- **LICENSE (MIT) + NOTICE** — Explicit MIT licence file for this repo plus an Apache-2.0 attribution notice for sparkrun, consistent with sublicensing under Section 4 of that licence.

### Changed

- **`setup/dgx-global-base-setup.sh`** — Installs [uv](https://github.com/astral-sh/uv) and `uv tool install --force --editable vendor/sparkrun`. Runs the DGX mode picker on first boot.
- **`scripts/eval-checkpoint.sh`** — Launches the `eval-checkpoint` recipe via `sparkrun run` (port defaults to `$EVAL_VLLM_PORT`, default `8021`) instead of a hand-built `docker run`. Model registration now uses `sparkrun proxy alias add` instead of appending to `~/.litellm/config.yaml`. `--stop-vllm` still works as a backward-compatible alias for `--stop-production`.
- **`scripts/autoresearch-deregister.sh`** — Rewritten on top of `sparkrun proxy unload`.
- **`scripts/demo-autoresearch.sh`** — Backend readiness check uses `sparkrun status`; LiteLLM-reload note updated to reflect the management-API path.
- **`harness/start-harness.sh`** — Log banner clarifies the upstream proxy is sparkrun on `:4000`.
- **`harness/eval/lm_model.py`** — Docstring clarifies that `litellm_url` now refers to the sparkrun proxy (same port, same wire protocol). `litellm_url` kwarg kept for backward compatibility with existing `HarnessLM` callers.
- **`docker-compose.inference.yml`** — Pruned to Open-WebUI only. Model serving and proxy moved to sparkrun.
- **`example.bash_aliases`** — `vllm*` and `litellm*` aliases now wrap `sparkrun` / `sparkrun proxy`. Added `dgx-mode`, `vllm-status`, `vllm-logs`, `vllm-show`, `litellm-models`, `litellm-alias`, `autoresearch-deregister`, `eval-checkpoint`. `inference-up` / `inference-down` start/stop Open-WebUI + sparkrun proxy together.
- **`status.sh`** — Reports `sparkrun proxy` and `sparkrun status` instead of querying raw LiteLLM / vLLM containers.
- **`README.md`** — Version badge 1.3.1 → 1.5.0. Rewrote the Inference Playground section around sparkrun; refreshed Architecture diagram, Cross-Tool Integrations, Safety Harness quick-start, NVIDIA Sync mapping, Port Reference, and Suggested Aliases. Added **Third-Party Software** section and a submodule-aware **License** paragraph.

### Removed

- **`inference/start-vllm.sh`**, **`inference/start-vllm-sync.sh`** — Superseded by `sparkrun run` against recipes in `recipes/` or `vendor/sparkrun/recipes/`.
- **`inference/start-litellm.sh`**, **`inference/start-litellm-sync.sh`**, **`inference/setup-litellm-config.sh`** — Superseded by `sparkrun proxy start` + `sparkrun proxy alias add`. The proxy still binds `:4000` for wire-level compatibility.
- **`scripts/_litellm_register.py`**, **`scripts/test-eval-register.sh`** — The hand-rolled LiteLLM config-file mutator and its test are obsolete now that proxy routing is controlled through the sparkrun CLI.
- **`example.vllm-model`** — Default model is now encoded in `recipes/nemotron-3-nano-4b-bf16-vllm.yaml`.

### Migration

1. `git pull && git submodule update --init --recursive` (or re-clone with `--recurse-submodules`).
2. Re-run `bash setup/dgx-global-base-setup.sh` to install uv + sparkrun and run the DGX mode picker.
3. Replace any direct uses of `start-vllm.sh` / `start-litellm.sh` in your own scripts with `sparkrun run <recipe>` / `sparkrun proxy start`. Downstream consumers pointing at `http://localhost:4000` (harness, eval-toolbox `lm_eval`, Open-WebUI, n8n, custom code) need no changes.
4. If you maintained a custom `~/.litellm/config.yaml`, port each entry to `sparkrun proxy alias add <name> <provider/model>` — or keep the file and point sparkrun at it via its `--config` passthrough.
5. Update any NVIDIA Sync custom apps that referenced `start-vllm-sync.sh` / `start-litellm-sync.sh` to the sparkrun commands in the README's NVIDIA Sync table.

### Risk notes

- sparkrun proxy binds the same `:4000` port as the legacy LiteLLM container, so every downstream HTTP consumer keeps working unchanged.
- Only three files in this repo previously edited `~/.litellm/config.yaml` directly (`scripts/_litellm_register.py`, `scripts/autoresearch-deregister.sh`, `scripts/eval-checkpoint.sh`) — all have been rewritten or removed. No other file path depends on LiteLLM's on-disk config format.
- The legacy `8020` vLLM port is dropped in favour of each recipe's own `defaults.port` (the shipped `nemotron` recipe uses `:8000`). If you had external tools pinned to `:8020`, either override with `sparkrun run ... --port 8020` or edit the recipe.

## 2026-04-20 — Claude AI & Ollama Integration (v1.4.0)

### Added

- **scripts/claude-ollama.sh** — New wrapper script for Claude Code to use local Ollama models. Includes model selection, environment variable management, and session tracking.
- **example.bash_aliases** — Added `claude-ollama` alias under new `Claude AI` section.

### Changed

- **README.md** — Updated "Key aliases" table to include `claude-ollama`.

## 2026-04-05 — Revert vLLM --user Flag (v1.3.4)

### Fixed

- **start-vllm.sh / start-vllm-sync.sh** — Removed `--user "$(id -u):$(id -g)"` from `docker run`. The vLLM image calls `getpwuid()` during startup and crashes with `KeyError: uid not found` when given a host uid that doesn't exist in the container's `/etc/passwd`

## 2026-04-03 — MLflow in Base Toolbox (v1.3.3)

### Changed

- **base-toolbox Dockerfile** — Added `mlflow` to base image so all containers (eval-toolbox, data-toolbox, unsloth-headless) inherit it. Previously only eval-toolbox had mlflow, but training (`train_model.py`) also requires it for experiment tracking
- **eval-toolbox Dockerfile** — Removed `mlflow` from eval-specific layer (now inherited from base)

## 2026-04-03 — vLLM User Namespace Fix (v1.3.2)

### Fixed

- **start-vllm.sh / start-vllm-sync.sh** — Added `--user "$(id -u):$(id -g)"` to `docker run` so container-created files on mounted volumes match host user ownership. Previously, vLLM containers created output directories as root, blocking host-side eval scripts from writing to them

## 2026-04-03 — Base Toolbox ML Deps (v1.3.1)

### Changed

- **base-toolbox Dockerfile** — Added ML training stack (`transformers`, `accelerate`, `peft`, `trl`, `sentencepiece`, `hf_transfer`, `pyyaml`) to the shared base image so eval-toolbox, data-toolbox, and unsloth-headless containers inherit a working ML environment without per-container workarounds

### Fixed

- **keras_nlp backend conflict** — Added `pip uninstall -y keras-nlp keras keras-core` layer before pip install to remove the NGC PyTorch 26.02 keras stub that conflicts with transformers 4.56+

## 2026-04-01 — GPU Telemetry and Adaptive Training Support (v1.3.0)

### Added

- **GPU telemetry package** — Installable Python package at `telemetry/` with `pip install -e` support. Provides hardware-aware primitives for training on DGX Spark without direct NVML or `/proc` calls
- **GPUSampler** — Wraps pynvml for GPU power, temperature, and utilization; always reads memory from `/proc/meminfo` MemAvailable (GB10 UMA architecture). Mock mode for CI without GPU hardware. Per-metric degradation: individual NVML calls fail independently to `None`
- **UMA memory model** — `sample_baseline()` with page cache drop (graceful `PermissionError` fallback) and `calculate_headroom()` with 5 GB jitter margin, `pin_memory=False`, `prefetch_factor` capped at 4
- **Effective scale formula** — Multiplier tables for quantization, gradient checkpointing, LoRA rank, sequence length, and optimizer. Four tier thresholds: ≤1B (cap=64), 1-13B (cap=16), 13-30B (cap=8), 30B+ (cap=4)
- **Anchor store** — JSON persistence of proven batch configs keyed by SHA-256 hash of 9 locked fields. 7-day expiry. Override rules: COMPLETED raises ceiling, OOM/WATCHDOG hard cap, HANG logs only (no batch_cap)
- **Probe protocol** — `prepare_probe()` writes rollback and probe configs; `evaluate_probe()` returns commit/revert with anchor record based on peak memory vs safe threshold
- **Failure classifier** — Classifies training outcomes as clean, oom, hang, thermal, or pressure from telemetry snapshots. HANG intentionally omits `batch_cap` to prevent incorrect batch backoff
- **Integration** — `dgx_toolbox.py` `status_report()` includes `gpu_telemetry` section when package installed; `status.sh` displays GPU TELEMETRY block with watts/temp/utilization or "sampler not installed"

## 2026-03-31 — Headless Training & MLflow (v1.2.3)

### Added

- **Headless Unsloth container** — `containers/unsloth-headless.sh` and `unsloth-headless-sync.sh` for autonomous training pipelines. Installs Unsloth deps then idles via `sleep infinity`, avoiding Studio UI restart loops on NGC base images

### Changed

- **MLflow replaces W&B** — Switched from Weights & Biases to MLflow with local file store for experiment tracking, eliminating cloud account dependency during training and evaluation

### Fixed

- **Memory fragmentation OOM** — Set `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` in headless containers to prevent caching allocator fragmentation on DGX Spark's unified memory architecture

## 2026-03-28 — Example Entry Points (v1.2.2)

### Added

- **Example entry points** — `examples/dgx_toolbox.py` (Python execution engine) and `examples/dgx_toolbox.yaml` (sample config) for integrating DGX Toolbox into external projects. Copy both files into your project and customize the YAML to map your containers, workdirs, and pinned deps
- **README** — New "Using DGX Toolbox from External Projects" section with usage examples

## 2026-03-28 — Extra Bind Mounts (v1.2.1)

### Added

- **Extra bind mounts** — All container scripts now support `EXTRA_MOUNTS` env var for mounting additional host directories (e.g., `EXTRA_MOUNTS="$HOME/projects/myproject:/workspace/myproject"`). Comma-separated for multiple mounts. Invalid specs warn to stderr and are skipped. Implemented via shared `build_extra_mounts()` in `lib.sh`

### Changed

- **Container scripts** — `unsloth-studio.sh`, `unsloth-studio-sync.sh`, `ngc-pytorch.sh`, `ngc-jupyter.sh`, and `start-n8n.sh` all source `lib.sh` and include extra mount support

## 2026-03-25 — Autoresearch Integration (v1.2)

### Added

- **Autoresearch pipeline** — End-to-end demo script (`scripts/demo-autoresearch.sh`) with data selection, optional safety screening, training, post-training eval, and model registration
- **Training data screening** — `scripts/screen-data.sh` pre-screens training data through harness guardrails (PII, toxicity)
- **Post-training safety eval** — `scripts/eval-checkpoint.sh` supports HuggingFace checkpoints (temp vLLM + replay eval) and PyTorch raw checkpoints (training metrics extraction)
- **Smart checkpoint saving** — Only saves when `val_bpb` improves (prevents disk buildup in autonomous mode). Epoch-timestamped filenames with `model.pt` symlink to latest best. Tracks best score in `best.json`
- **DGX Spark compatibility** — `spark-config.sh` disables torch.compile and flash-attn3 (GB10 CUDA 12.1), replaces with PyTorch SDPA, fixes batch size math, injects checkpoint saving
- **HuggingFace token caching** — Demo prompts for HF_TOKEN on first run, caches at `~/.cache/huggingface/token`, offers release option on subsequent runs
- **Data source navigation** — Press Enter at any input prompt to go back to the main menu; option 6 sub-menu has Back option
- **Autonomous Agent Mode** — README section documenting how to run the full LLM agent loop with `claude "Read program.md"`, including `program.md` DGX Spark constraints patch
- **Model registration/deregistration** — Auto-register in LiteLLM on pass, `autoresearch-deregister.sh` for cleanup
- **Kaggle CLI** — Pre-installed in base setup script with API token setup instructions
- **CI security** — Secret leak detection and dependency vulnerability scanning in GitHub Actions
- **README** — Walkthrough, autonomous mode, Ollama local model tip, version/author/badges

## 2026-03-24 — Safety Harness Fixes & Polish

### Fixed

- **Replay eval rate limiting** — TPM boundary off-by-one (`>` → `>=`), retry backoff too short for 60s sliding window, transport errors (429/404/502/503/timeout) now retried with exponential backoff [2s, 4s, 8s, 16s, 65s]
- **Replay eval error handling** — Transport errors no longer misclassified as "allow"; new `error_cases` counter excludes them from F1/precision/recall; CLI prints warning when errors > 0
- **Replay eval timeout** — Increased httpx timeout from 60s to 180s for shared-GPU inference; `ReadTimeout` caught and retried instead of crashing
- **Default model** — Changed default from `llama3.1` to `nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16` (matches DGX Spark vLLM config)
- **vLLM compose** — Added `--trust-remote-code` and configurable `--gpu-memory-utilization` (default 0.5) for coexistence with other GPU workloads
- **Dev-team rate limits** — Increased from 60 RPM / 100K TPM to 600 RPM / 1M TPM for eval replay runs
- **Dev-team allowed models** — Changed from restricted list to wildcard (`"*"`)
- **HITL Gradio select** — Fixed row selection crash (`NameError: 'gr' is not defined`) caused by PEP 563 lazy annotations; `select_item.__annotations__` now assigned as actual class object to bypass `typing.get_type_hints()` string resolution
- **HITL guardrail_decisions** — Fixed `'list' object has no attribute 'get'` in `_action_taken` and `_extract_triggering_rail_inline` (guardrail_decisions stored as JSON list, not dict)
- **HITL default API URL** — Changed from `:8080` to `:5000` (matching actual harness port)

### Changed

- **gradio and asciichartpy** moved from optional to core dependencies — installed by default with `pip install -e .`
- **Default model** — Set to `nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16` across eval CLI, docker-compose, LiteLLM config, and vllm-model (was `llama3.1` which didn't exist in LiteLLM)
- **HITL queue** — `compute_priority` and `_extract_triggering_rail` now handle `guardrail_decisions` stored as JSON list (not just dict)
- **LiteLLM config** — Removed stale `Qwen/Qwen3.5-2B` entry that caused 404→429 cascading failures
- **.gitignore** — Fixed path from `safety-harness/` to `harness/`, added trace DB and pending dataset ignores
- **example.bash_aliases** — Added `harness`, `harness-stop`, `hitl` aliases
- **HITL dashboard layout** — Queue table full-width on top, detail panel below; original output and diff side-by-side; reviewer input single-line with placeholder
- **HITL API key** — Uses `HARNESS_API_KEY` env var (not hardcoded in alias) for multi-tenant support
- **README** — Added step-by-step startup guide, OpenAI SDK example, HITL dashboard section, stopping instructions

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

- **eval-toolbox/Dockerfile** — NGC PyTorch base + Python-level eval stack (lm-eval, ragas, torchmetrics, pycocotools, mlflow, tritonclient, etc.)
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
