# ============================================================================
# DGX Toolbox — Example Aliases
# Copy to ~/.bash_aliases:  cp ~/dgx-toolbox/example.bash_aliases ~/.bash_aliases && source ~/.bash_aliases
#
# NOTE: Model serving and the OpenAI-compatible proxy are now delegated to
# sparkrun (https://github.com/spark-arena/sparkrun), vendored under
# vendor/sparkrun. The `vllm*` and `litellm*` aliases below are thin wrappers
# that preserve the old muscle memory while delegating to sparkrun under the
# hood. The proxy still binds :4000, so anything pointing at
# http://localhost:4000 (harness, eval, Open-WebUI, etc.) keeps working.
# ============================================================================

# --- Claude AI ---
alias claude-ollama='source ~/dgx-toolbox/scripts/claude-ollama.sh'               # Use local Ollama models with Claude Code
alias claude-ollama-danger='source ~/dgx-toolbox/scripts/claude-ollama.sh --dangerously-skip-permissions' # Use Ollama models with Claude Code (skip permissions)
alias claude-litellm='source ~/dgx-toolbox/scripts/claude-litellm.sh'             # Route Claude Code through sparkrun proxy (LiteLLM, :4000)
alias claude-litellm-danger='source ~/dgx-toolbox/scripts/claude-litellm.sh --dangerously-skip-permissions' # Claude Code via sparkrun proxy (skip permissions)
alias claude-danger='claude --dangerously-skip-permissions'                     # Native Claude Code (skip permissions)

# --- Inference Playground (Open-WebUI container) ---
alias open-webui='~/dgx-toolbox/inference/start-open-webui.sh'              # Chat UI with Ollama / sparkrun-served models (:12000)
alias open-webui-stop='docker stop open-webui'                                # Stop Open-WebUI
alias ollama-remote='~/dgx-toolbox/inference/setup-ollama-remote.sh'          # Enable Ollama LAN access (sudo)

# --- Model serving (sparkrun) ---
# `sparkrun run` launches a recipe (vLLM container by default). Sparkrun does
# not expose a --recipe-path flag: recipe names are resolved against the
# registered registries (see `dgx-recipes list`) and the CWD, or a direct
# path to a recipe YAML can be passed. The `vllm` function below is a thin
# wrapper that first looks for the recipe in this repo's local recipes/
# directory, then falls back to sparkrun's normal resolution. Examples:
#   vllm nemotron-3-nano-4b-bf16-vllm            # local recipes/ first, then registries
#   vllm nemotron-3-nano-4b-bf16-vllm --solo     # force single-node
#   vllm qwen3.6                                 # resolves from registered registries
#   vllm ~/my-recipes/custom.yaml                # direct path to any recipe YAML
#
# Sparkrun resolves hosts BEFORE loading the recipe and exits if none are
# configured. `dgx-mode single` registers a `solo` cluster (hosts=localhost)
# as sparkrun's default to satisfy this. As a defensive fallback for users on
# installs that pre-date that fix, this wrapper also injects --hosts localhost
# when DGX_MODE=single and the caller hasn't passed any host flag.
#
# Auto-registration with the LiteLLM proxy: by default, after launching a
# workload the wrapper spawns a background watchdog that waits for the model
# to come up and calls `sparkrun proxy models --refresh` so the new endpoint
# appears in the LiteLLM routing table. Opt out with DGX_PROXY_AUTOREGISTER=0
# (env or mode.env). Skipped automatically for --foreground / --dry-run.
#
# NOTE: `unalias` first so re-sourcing this file after an older install
# (where vllm was an alias) does not trip a syntax error when the alias is
# expanded inside the function definition.
unalias vllm 2>/dev/null || true

# Internal: background watchdog that polls until the LiteLLM proxy registers
# a new model, then exits. Kept as a separate function so the body is
# testable in isolation and so `disown` / `&` redirects stay legible.
_dgx_vllm_autoregister_watchdog() {
  # 240 * 5s = 1200s = 20 min max. Long enough for a cold image build on a
  # fresh host; short enough to not linger indefinitely if the launch fails.
  local _attempts=240
  while [ "$_attempts" -gt 0 ]; do
    sleep 5
    _attempts=$(( _attempts - 1 ))
    # Proxy must be running for a refresh to do anything useful.
    if ! sparkrun proxy status --json 2>/dev/null | grep -q '"running":[[:space:]]*true'; then
      continue
    fi
    local _out
    _out=$(sparkrun proxy models --refresh 2>&1) || continue
    if echo "$_out" | grep -qE 'Synced proxy models:.* added'; then
      echo "[vllm] Registered new workload with LiteLLM proxy (:4000)" >&2
      return 0
    fi
  done
  return 1
}

vllm() {
  if [ "$#" -lt 1 ]; then
    echo "Usage: vllm <recipe-name|path/to/recipe.yaml> [sparkrun run options...]" >&2
    return 1
  fi
  local _recipe="$1"; shift
  local _local="$HOME/dgx-toolbox/recipes/${_recipe}.yaml"

  # Read DGX_MODE and DGX_PROXY_AUTOREGISTER from env, falling back to
  # ~/.config/dgx-toolbox/mode.env.
  local _mode_env="${DGX_TOOLBOX_CONFIG_DIR:-$HOME/.config/dgx-toolbox}/mode.env"
  local _dgx_mode="${DGX_MODE:-}"
  local _dgx_autoreg="${DGX_PROXY_AUTOREGISTER:-}"
  if { [ -z "$_dgx_mode" ] || [ -z "$_dgx_autoreg" ]; } && [ -f "$_mode_env" ]; then
    local _env_mode _env_autoreg
    # shellcheck disable=SC1090
    _env_mode="$(. "$_mode_env" && echo "${DGX_MODE:-}")"
    # shellcheck disable=SC1090
    _env_autoreg="$(. "$_mode_env" && echo "${DGX_PROXY_AUTOREGISTER:-}")"
    [ -z "$_dgx_mode" ] && _dgx_mode="$_env_mode"
    [ -z "$_dgx_autoreg" ] && _dgx_autoreg="$_env_autoreg"
  fi
  # Default: autoregister ON unless explicitly disabled.
  if [ -z "$_dgx_autoreg" ]; then
    _dgx_autoreg=1
  fi

  # Defensive fallback: if the user is in single-node mode and passed no host
  # flag, inject --hosts localhost so sparkrun's pre-recipe host check passes.
  # Normally dgx-mode single registers a default cluster, but older installs
  # may not have re-run it. Also detect --foreground / --dry-run which change
  # autoregister semantics.
  local _has_host_flag=0 _is_foreground=0 _is_dry_run=0 _arg
  for _arg in "$@"; do
    case "$_arg" in
      --hosts|--hosts=*|-H|--hosts-file|--hosts-file=*|--cluster|--cluster=*|--solo)
        _has_host_flag=1 ;;
      --foreground)
        _is_foreground=1 ;;
      --dry-run)
        _is_dry_run=1 ;;
    esac
  done
  local _host_args=()
  if [ "$_dgx_mode" = "single" ] && [ "$_has_host_flag" -eq 0 ]; then
    _host_args=(--hosts localhost)
  fi

  # Spawn the autoregister watchdog BEFORE launching so it runs concurrently
  # with sparkrun's foreground log-follow. Skipped when the user explicitly
  # opted out, or when semantics don't fit (dry-run, foreground).
  if [ "$_dgx_autoreg" = "1" ] && [ "$_is_foreground" -eq 0 ] && [ "$_is_dry_run" -eq 0 ]; then
    ( _dgx_vllm_autoregister_watchdog ) >&2 &
    disown 2>/dev/null || true
  fi

  if [ -f "$_recipe" ]; then
    sparkrun run "$_recipe" "${_host_args[@]}" "$@"
  elif [ -f "$_local" ]; then
    sparkrun run "$_local" "${_host_args[@]}" "$@"
  else
    sparkrun run "$_recipe" "${_host_args[@]}" "$@"
  fi
}
alias vllm-stop='sparkrun stop'                                               # Stop the active sparkrun workload
alias vllm-logs='sparkrun logs'                                               # Tail logs of the active workload
alias vllm-status='sparkrun status'                                           # Show running workload + proxy status
alias vllm-show='sparkrun show'                                               # Print resolved recipe config

# --- OpenAI-compatible proxy (sparkrun proxy → LiteLLM under the hood, :4000) ---
alias litellm='sparkrun proxy start'                                          # Start proxy on :4000
alias litellm-stop='sparkrun proxy stop'                                      # Stop proxy
alias litellm-status='sparkrun proxy status'                                  # Proxy status
alias litellm-models='sparkrun proxy models --refresh'                        # Refresh and list routed models
alias litellm-alias='sparkrun proxy alias'                                    # Manage proxy aliases (add/remove/list)

# --- DGX mode (single vs. cluster) ---
alias dgx-mode='~/dgx-toolbox/setup/dgx-mode.sh'                              # dgx-mode single | cluster <host1,host2,...> | status

# --- Recipe registries (official + community, via sparkrun) ---
alias dgx-recipes='~/dgx-toolbox/setup/dgx-recipes.sh'                        # dgx-recipes add | list | update | status
alias dgx-discover='~/dgx-toolbox/setup/dgx-discover.sh'                      # dgx-discover [list|local|registries|search <q>|show <r>|update]

# --- Fine-Tuning ---
alias unsloth-studio='~/dgx-toolbox/containers/unsloth-studio.sh'             # Unsloth fine-tuning UI (:8000)
alias unsloth-stop='docker stop unsloth-studio'                               # Stop Unsloth Studio

# --- Autonomous Research ---
alias autoresearch='~/dgx-toolbox/karpathy-autoresearch/launch-autoresearch.sh'     # Karpathy autoresearch agent
alias autoresearch-stop='pkill -f "uv run train.py" 2>/dev/null && echo "Stopped" || echo "Not running"'  # Stop experiment
alias autoresearch-deregister='~/dgx-toolbox/scripts/autoresearch-deregister.sh'    # Remove autoresearch models from sparkrun proxy
alias demo-autoresearch='~/dgx-toolbox/scripts/demo-autoresearch.sh'                 # Full pipeline demo (data -> train -> eval -> inference)
alias eval-checkpoint='~/dgx-toolbox/scripts/eval-checkpoint.sh'                     # Evaluate a local checkpoint via sparkrun (ephemeral :8021)

# --- GPU Containers ---
alias ngc-pytorch='~/dgx-toolbox/containers/ngc-pytorch.sh'                   # Interactive PyTorch shell (GPU)
alias ngc-jupyter='~/dgx-toolbox/containers/ngc-jupyter.sh'                   # Jupyter Lab on NGC PyTorch (:8888)

# --- Data Engineering ---
alias data-build='~/dgx-toolbox/data/data-toolbox-build.sh'                   # Build data-toolbox image
alias data-toolbox='~/dgx-toolbox/data/data-toolbox.sh'                       # Interactive data processing shell (GPU)
alias data-jupyter='~/dgx-toolbox/data/data-toolbox-jupyter.sh'               # Jupyter Lab with data stack (:8890)

# --- Labeling Platforms ---
alias label-studio='~/dgx-toolbox/data/start-label-studio.sh'                 # Data annotation UI (:8081)
alias label-studio-stop='docker stop label-studio'                            # Stop Label Studio
alias argilla='~/dgx-toolbox/data/start-argilla.sh'                           # AI feedback & annotation UI (:6900)
alias argilla-stop='docker stop argilla'                                      # Stop Argilla

# --- Evaluation ---
alias eval-build='~/dgx-toolbox/eval/eval-toolbox-build.sh'                   # Build eval-toolbox image
alias eval-toolbox='~/dgx-toolbox/eval/eval-toolbox.sh'                       # Interactive eval shell (GPU)
alias eval-jupyter='~/dgx-toolbox/eval/eval-toolbox-jupyter.sh'               # Jupyter Lab with eval stack (:8889)

# --- Inference Servers ---
alias triton='~/dgx-toolbox/eval/triton-trtllm.sh'                            # Triton + TRT-LLM server (:8010-8012)
alias triton-stop='docker stop triton-trtllm'                                 # Stop Triton

# --- Workflow Automation ---
alias n8n='~/dgx-toolbox/containers/start-n8n.sh'                             # n8n workflow automation (:5678)
alias n8n-stop='docker stop n8n'                                              # Stop n8n

# --- Orchestration (docker-compose + sparkrun) ---
alias build-all='~/dgx-toolbox/build-toolboxes.sh'                                                                          # Build base + eval + data images
alias inference-up='docker compose -f ~/dgx-toolbox/docker-compose.inference.yml up -d open-webui && sparkrun proxy start'  # Open-WebUI + sparkrun proxy (:4000)
alias inference-down='sparkrun proxy stop && docker compose -f ~/dgx-toolbox/docker-compose.inference.yml down'             # Stop proxy + Open-WebUI
alias inference-logs='docker compose -f ~/dgx-toolbox/docker-compose.inference.yml logs -f'                                 # Stream Open-WebUI logs (sparkrun has vllm-logs)
alias data-stack-up='docker compose -f ~/dgx-toolbox/docker-compose.data.yml up -d'                                         # Start Label Studio + Argilla
alias data-stack-down='docker compose -f ~/dgx-toolbox/docker-compose.data.yml down'                                        # Stop data stack

# --- Safety Harness ---
alias harness='~/dgx-toolbox/harness/start-harness.sh'                            # Safety gateway (:5000) — proxies to sparkrun's LiteLLM (:4000) with guardrails
alias harness-stop='pkill -f "uvicorn harness.main:app" 2>/dev/null && echo "Harness stopped" || echo "Not running"'  # Stop safety harness
alias hitl='python -m harness.hitl ui --port 8501'                                 # HITL review dashboard (:8501) — set HARNESS_API_KEY or pass --api-key

# --- Model Store ---
alias modelstore='~/dgx-toolbox/modelstore.sh'                                    # Tiered model storage manager

# --- Utilities ---
alias dgx-status='~/dgx-toolbox/status.sh'                                        # Show all services, images, disk usage
alias docker-stop-all='docker stop $(docker ps -q) 2>/dev/null && echo "All containers stopped" || echo "No running containers"' # Stop every running container
