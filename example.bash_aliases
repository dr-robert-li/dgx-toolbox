# ============================================================================
# DGX Toolbox — Example Aliases
# Copy to ~/.bash_aliases:  cp ~/dgx-toolbox/example.bash_aliases ~/.bash_aliases && source ~/.bash_aliases
# ============================================================================

# --- Inference Playground ---
alias open-webui='~/dgx-toolbox/inference/start-open-webui.sh'              # Chat UI with Ollama/LiteLLM/vLLM (:12000)
alias open-webui-stop='docker stop open-webui'                    # Stop Open-WebUI
alias vllm='~/dgx-toolbox/inference/start-vllm.sh'                         # High-throughput inference server (:8020)
alias vllm-stop='docker stop vllm && docker rm vllm'              # Stop vLLM
alias litellm='~/dgx-toolbox/inference/start-litellm.sh'                   # Unified API proxy for all backends (:4000)
alias litellm-stop='docker stop litellm'                          # Stop LiteLLM
alias litellm-config='~/dgx-toolbox/inference/setup-litellm-config.sh'     # Auto-detect services + set API keys
alias ollama-remote='~/dgx-toolbox/inference/setup-ollama-remote.sh'       # Enable Ollama LAN access (sudo)

# --- Fine-Tuning ---
alias unsloth-studio='~/dgx-toolbox/containers/unsloth-studio.sh'           # Unsloth fine-tuning UI (:8000)
alias unsloth-stop='docker stop unsloth-studio'                   # Stop Unsloth Studio

# --- Autonomous Research ---
alias autoresearch='~/dgx-toolbox/karpathy-autoresearch/launch-autoresearch.sh'   # Karpathy autoresearch agent (:local)
alias autoresearch-stop='pkill -f "uv run train.py" 2>/dev/null && echo "Stopped" || echo "Not running"'  # Stop running experiment

# --- GPU Containers ---
alias ngc-pytorch='~/dgx-toolbox/containers/ngc-pytorch.sh'                 # Interactive PyTorch shell (GPU)
alias ngc-jupyter='~/dgx-toolbox/containers/ngc-jupyter.sh'                 # Jupyter Lab on NGC PyTorch (:8888)

# --- Data Engineering ---
alias data-build='~/dgx-toolbox/data/data-toolbox-build.sh'           # Build data-toolbox image
alias data-toolbox='~/dgx-toolbox/data/data-toolbox.sh'               # Interactive data processing shell (GPU)
alias data-jupyter='~/dgx-toolbox/data/data-toolbox-jupyter.sh'       # Jupyter Lab with data stack (:8890)

# --- Labeling Platforms ---
alias label-studio='~/dgx-toolbox/data/start-label-studio.sh'         # Data annotation UI (:8081)
alias label-studio-stop='docker stop label-studio'                # Stop Label Studio
alias argilla='~/dgx-toolbox/data/start-argilla.sh'                   # AI feedback & annotation UI (:6900)
alias argilla-stop='docker stop argilla'                          # Stop Argilla

# --- Evaluation ---
alias eval-build='~/dgx-toolbox/eval/eval-toolbox-build.sh'           # Build eval-toolbox image
alias eval-toolbox='~/dgx-toolbox/eval/eval-toolbox.sh'               # Interactive eval shell (GPU)
alias eval-jupyter='~/dgx-toolbox/eval/eval-toolbox-jupyter.sh'       # Jupyter Lab with eval stack (:8889)

# --- Inference Servers ---
alias triton='~/dgx-toolbox/eval/triton-trtllm.sh'                   # Triton + TRT-LLM server (:8010-8012)
alias triton-stop='docker stop triton-trtllm'                    # Stop Triton

# --- Workflow Automation ---
alias n8n='~/dgx-toolbox/containers/start-n8n.sh'                           # n8n workflow automation (:5678)
alias n8n-stop='docker stop n8n'                                  # Stop n8n

# --- Orchestration (docker-compose) ---
alias build-all='~/dgx-toolbox/build-toolboxes.sh'               # Build base + eval + data images
alias inference-up='docker compose -f ~/dgx-toolbox/docker-compose.inference.yml up -d'    # Start Open-WebUI + LiteLLM
alias inference-down='docker compose -f ~/dgx-toolbox/docker-compose.inference.yml down'    # Stop inference stack
alias inference-logs='docker compose -f ~/dgx-toolbox/docker-compose.inference.yml logs -f' # Stream inference logs
alias data-stack-up='docker compose -f ~/dgx-toolbox/docker-compose.data.yml up -d'        # Start Label Studio + Argilla
alias data-stack-down='docker compose -f ~/dgx-toolbox/docker-compose.data.yml down'        # Stop data stack

# --- Model Store ---
alias modelstore='~/dgx-toolbox/modelstore.sh'               # Tiered model storage manager

# --- Utilities ---
alias dgx-status='~/dgx-toolbox/status.sh'                       # Show all services, images, disk usage
alias docker-stop-all='docker stop $(docker ps -q) 2>/dev/null && echo "All containers stopped" || echo "No running containers"' # Stop every running container
