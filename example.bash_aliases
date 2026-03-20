# DGX Toolbox — Example Aliases
# Copy to ~/.bash_aliases:  cp ~/dgx-toolbox/example.bash_aliases ~/.bash_aliases && source ~/.bash_aliases

# --- Inference Playground ---
alias open-webui='~/dgx-toolbox/start-open-webui.sh'
alias open-webui-stop='docker stop open-webui'
alias vllm='~/dgx-toolbox/start-vllm.sh'
alias vllm-stop='docker stop vllm && docker rm vllm'
alias litellm='~/dgx-toolbox/start-litellm.sh'
alias litellm-stop='docker stop litellm'
alias litellm-config='~/dgx-toolbox/setup-litellm-config.sh'
alias ollama-remote='~/dgx-toolbox/setup-ollama-remote.sh'

# --- Fine-Tuning ---
alias unsloth-studio='~/dgx-toolbox/unsloth-studio.sh'
alias unsloth-stop='docker stop unsloth-studio'

# --- GPU Containers ---
alias ngc-pytorch='~/dgx-toolbox/ngc-pytorch.sh'
alias ngc-jupyter='~/dgx-toolbox/ngc-jupyter.sh'

# --- Data Engineering ---
alias data-build='~/dgx-toolbox/data-toolbox-build.sh'
alias data-toolbox='~/dgx-toolbox/data-toolbox.sh'
alias data-jupyter='~/dgx-toolbox/data-toolbox-jupyter.sh'

# --- Labeling Platforms ---
alias label-studio='~/dgx-toolbox/start-label-studio.sh'
alias label-studio-stop='docker stop label-studio'
alias argilla='~/dgx-toolbox/start-argilla.sh'
alias argilla-stop='docker stop argilla'

# --- Evaluation ---
alias eval-build='~/dgx-toolbox/eval-toolbox-build.sh'
alias eval-toolbox='~/dgx-toolbox/eval-toolbox.sh'
alias eval-jupyter='~/dgx-toolbox/eval-toolbox-jupyter.sh'

# --- Inference Servers ---
alias triton='~/dgx-toolbox/triton-trtllm.sh'
alias triton-stop='docker stop triton-trtllm'

# --- Workflow Automation ---
alias n8n='~/dgx-toolbox/start-n8n.sh'
alias n8n-stop='docker stop n8n'

# --- Orchestration (docker-compose) ---
alias build-all='~/dgx-toolbox/build-toolboxes.sh'
alias inference-up='docker compose -f ~/dgx-toolbox/docker-compose.inference.yml up -d'
alias inference-down='docker compose -f ~/dgx-toolbox/docker-compose.inference.yml down'
alias inference-logs='docker compose -f ~/dgx-toolbox/docker-compose.inference.yml logs -f'
alias data-stack-up='docker compose -f ~/dgx-toolbox/docker-compose.data.yml up -d'
alias data-stack-down='docker compose -f ~/dgx-toolbox/docker-compose.data.yml down'

# --- Utilities ---
alias dgx-status='~/dgx-toolbox/status.sh'
alias docker-stop-all='docker stop $(docker ps -q) 2>/dev/null && echo "All containers stopped" || echo "No running containers"'
