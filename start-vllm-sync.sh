#!/usr/bin/env bash
# vLLM launcher for NVIDIA Sync — starts server, returns immediately
# Usage: start-vllm-sync.sh [model_name] [extra_args...]
#   If no model_name is given, reads from ~/.vllm-model
set -e

PORT=8020
CONTAINER_NAME="vllm"
IMAGE="vllm/vllm-openai:latest"
MODEL="${1:-}"
shift 2>/dev/null || true
EXTRA_ARGS="$*"

# Fall back to config file if no model argument
if [ -z "$MODEL" ] && [ -f "$HOME/.vllm-model" ]; then
    MODEL=$(head -1 "$HOME/.vllm-model" | xargs)
fi

if [ -z "$MODEL" ]; then
    echo "No model specified. Pass a model name or create ~/.vllm-model"
    echo "  echo 'meta-llama/Llama-3.1-8B-Instruct' > ~/.vllm-model"
    exit 1
fi

# Already running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "vLLM is already running on port ${PORT}"
    exit 0
fi

docker rm -f "$CONTAINER_NAME" 2>/dev/null

docker run -d \
    --name "$CONTAINER_NAME" \
    --gpus all \
    --ipc=host \
    -p 0.0.0.0:${PORT}:8000 \
    -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
    -v "$HOME/eval/models:/models" \
    --restart unless-stopped \
    "$IMAGE" \
    --model "$MODEL" \
    --host 0.0.0.0 \
    --port 8000 \
    $EXTRA_ARGS

echo "vLLM starting with model ${MODEL} on port ${PORT}"
echo "Stream logs with: docker logs -f ${CONTAINER_NAME}"
