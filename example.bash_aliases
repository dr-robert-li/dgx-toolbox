# ============================================================================
# DGX Toolbox — Example Aliases
# Copy to ~/.bash_aliases:  cp ~/dgx-toolbox/example.bash_aliases ~/.bash_aliases && source ~/.bash_aliases
#
# NOTE: Model serving and the OpenAI-compatible proxy are now delegated to
# sparkrun (https://github.com/spark-arena/sparkrun), vendored under
# vendor/sparkrun. The `vllm*` and `litellm*` commands below are real shell
# scripts under `~/dgx-toolbox/scripts/`, then exposed here as plain aliases
# so the stock `.bashrc` banner shows them on shell refresh. The proxy still
# binds :4000, so anything pointing at http://localhost:4000 (harness, eval,
# Open-WebUI, etc.) keeps working.
# ============================================================================

# --- Claude AI ---
alias claude-ollama='source ~/dgx-toolbox/scripts/claude-ollama.sh'               # Use local Ollama models with Claude Code
alias claude-ollama-danger='source ~/dgx-toolbox/scripts/claude-ollama.sh --dangerously-skip-permissions' # Use Ollama models with Claude Code (skip permissions)
alias claude-litellm='source ~/dgx-toolbox/scripts/claude-litellm.sh'             # Route Claude Code through sparkrun proxy (LiteLLM, :4000) via local SSE filter
alias claude-litellm-danger='source ~/dgx-toolbox/scripts/claude-litellm.sh --dangerously-skip-permissions' # Claude Code via sparkrun proxy (skip permissions)
alias sparkrun-claude='source ~/dgx-toolbox/scripts/sparkrun-claude/sparkrun-claude' # Portable sparkrun-claude package (same as claude-litellm — preferred name)
alias claude-danger='claude --dangerously-skip-permissions'                     # Native Claude Code (skip permissions)

# --- Inference Playground (Open-WebUI container) ---
alias open-webui='~/dgx-toolbox/inference/start-open-webui.sh'              # Chat UI with Ollama / sparkrun-served models (:12000)
alias open-webui-stop='docker stop open-webui'                                # Stop Open-WebUI
alias ollama-remote='~/dgx-toolbox/inference/setup-ollama-remote.sh'          # Enable Ollama LAN access (sudo)

# --- Model serving (sparkrun) ---
# `sparkrun run` launches a recipe (vLLM container by default). Sparkrun does
# not expose a --recipe-path flag: recipe names are resolved against the
# registered registries (see `dgx-recipes list`) and the CWD, or a direct
# path to a recipe YAML can be passed. The `vllm*` shell scripts below first
# look in this repo's local recipes/ directory, then fall back to sparkrun's
# normal resolution. They also preserve the single-node `--hosts localhost`
# injection and proxy auto-register behavior.
alias vllm='~/dgx-toolbox/scripts/vllm.sh'                                    # Run a sparkrun recipe (local recipes/ first, single-node safe)
alias vllm-stop='~/dgx-toolbox/scripts/vllm-stop.sh'                          # Stop a sparkrun workload (defaults to --all with no target)
alias vllm-logs='~/dgx-toolbox/scripts/vllm-logs.sh'                          # Tail sparkrun workload logs
alias vllm-status='~/dgx-toolbox/scripts/vllm-status.sh'                      # Show sparkrun workload status
alias vllm-show='~/dgx-toolbox/scripts/vllm-show.sh'                          # Show resolved sparkrun recipe config

# --- OpenAI-compatible proxy (sparkrun proxy → LiteLLM under the hood, :4000) ---
alias litellm='~/dgx-toolbox/scripts/litellm.sh'                              # Start proxy on :4000 (single-node safe)
alias litellm-stop='sparkrun proxy stop'                                      # Stop proxy
alias litellm-status='sparkrun proxy status'                                  # Proxy status
alias litellm-models='~/dgx-toolbox/scripts/litellm-models.sh'                # Refresh and list routed models (single-node safe)
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
alias inference-up='docker compose -f ~/dgx-toolbox/docker-compose.inference.yml up -d open-webui && litellm'              # Open-WebUI + sparkrun proxy wrapper (:4000)
alias inference-down='litellm-stop && docker compose -f ~/dgx-toolbox/docker-compose.inference.yml down'                   # Stop proxy + Open-WebUI
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
