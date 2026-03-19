#!/usr/bin/env bash
# vLLM OpenAI-compatible inference server
# Usage: start-vllm.sh [model_name] [extra_args...]
#   If no model_name is given, reads from ~/.vllm-model
# Example: start-vllm.sh meta-llama/Llama-3.1-8B-Instruct
# Example: start-vllm.sh unsloth/Llama-3.1-8B-Instruct --max-model-len 4096
set -e

PORT=8020
CONTAINER_NAME="vllm"
IMAGE="vllm/vllm-openai:latest"
MODEL="${1:-}"
shift 2>/dev/null || true
EXTRA_ARGS="$*"
IP=$(hostname -I | awk '{print $1}')

# Fall back to config file if no model argument
if [ -z "$MODEL" ] && [ -f "$HOME/.vllm-model" ]; then
    MODEL=$(head -1 "$HOME/.vllm-model" | xargs)
fi

if [ -z "$MODEL" ]; then
    echo "Usage: start-vllm.sh [model_name] [extra_args...]"
    echo ""
    echo "Examples:"
    echo "  start-vllm.sh meta-llama/Llama-3.1-8B-Instruct"
    echo "  start-vllm.sh unsloth/Llama-3.1-8B-Instruct --max-model-len 4096"
    echo "  start-vllm.sh /models/my-finetuned-model"
    echo ""
    echo "Or set a default model in ~/.vllm-model:"
    echo "  echo 'meta-llama/Llama-3.1-8B-Instruct' > ~/.vllm-model"
    echo ""
    echo "The model will be served as an OpenAI-compatible API on port ${PORT}."
    exit 1
fi

# If already running, show status
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "vLLM is already running on port ${PORT}"
    echo "Stop first with: docker stop vllm && docker rm vllm"
    exit 1
fi

docker rm -f "$CONTAINER_NAME" 2>/dev/null

echo "Starting vLLM with model: ${MODEL}"
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

echo ""
echo "========================================"
echo " vLLM Server"
echo "========================================"
echo "  Model:    ${MODEL}"
echo "  API:      http://localhost:${PORT}/v1"
echo "  LAN:      http://${IP}:${PORT}/v1"
echo "  Models:   http://localhost:${PORT}/v1/models"
echo ""
echo "  Usage:    curl http://localhost:${PORT}/v1/chat/completions \\"
echo "              -H 'Content-Type: application/json' \\"
echo "              -d '{\"model\": \"${MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}]}'"
echo ""
echo "  Stop:     docker stop vllm && docker rm vllm"
echo "========================================"
echo ""
echo "Streaming logs (Ctrl+C to detach, server keeps running)..."
docker logs -f "$CONTAINER_NAME"
