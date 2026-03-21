#!/usr/bin/env bash
# LiteLLM proxy — unified OpenAI-compatible endpoint for all backends
# Routes to Ollama, vLLM, and cloud APIs through a single endpoint
set -e

PORT=4000
CONTAINER_NAME="litellm"
IMAGE="ghcr.io/berriai/litellm:main-latest"
IP=$(hostname -I | awk '{print $1}')
CONFIG_DIR="$HOME/.litellm"

mkdir -p "$CONFIG_DIR"

# Create default config if not present
if [ ! -f "$CONFIG_DIR/config.yaml" ]; then
    cat > "$CONFIG_DIR/config.yaml" << 'YAML'
model_list:
  # Ollama models — add your pulled models here
  - model_name: llama3.1
    litellm_params:
      model: ollama/llama3.1
      api_base: http://host.docker.internal:11434
  - model_name: gemma3
    litellm_params:
      model: ollama/gemma3
      api_base: http://host.docker.internal:11434

  # vLLM models (when running) — uncomment and set model name
  # - model_name: vllm-model
  #   litellm_params:
  #     model: openai/your-model-name
  #     api_base: http://host.docker.internal:8020/v1
  #     api_key: "none"

  # Cloud APIs — set API keys as environment variables
  # - model_name: gpt-4o
  #   litellm_params:
  #     model: openai/gpt-4o
  # - model_name: claude-sonnet
  #   litellm_params:
  #     model: anthropic/claude-sonnet-4-20250514

litellm_settings:
  drop_params: true
  set_verbose: false
YAML
    echo "Created default config at $CONFIG_DIR/config.yaml"
    echo "Edit it to add your models and API keys."
fi

# Check if container already exists
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "LiteLLM is already running"
    else
        echo "Starting existing LiteLLM container..."
        docker start "$CONTAINER_NAME"
    fi
else
    echo "Creating LiteLLM container..."
    docker run -d \
        --name "$CONTAINER_NAME" \
        --add-host=host.docker.internal:host-gateway \
        -p 0.0.0.0:${PORT}:4000 \
        -v "$CONFIG_DIR/config.yaml:/app/config.yaml" \
        --env-file "$CONFIG_DIR/.env" 2>/dev/null \
        --restart unless-stopped \
        "$IMAGE" \
        --config /app/config.yaml --host 0.0.0.0 --port 4000 \
    || docker run -d \
        --name "$CONTAINER_NAME" \
        --add-host=host.docker.internal:host-gateway \
        -p 0.0.0.0:${PORT}:4000 \
        -v "$CONFIG_DIR/config.yaml:/app/config.yaml" \
        --restart unless-stopped \
        "$IMAGE" \
        --config /app/config.yaml --host 0.0.0.0 --port 4000
fi

echo ""
echo "========================================"
echo " LiteLLM Proxy"
echo " API:     http://localhost:${PORT}"
echo " LAN:     http://${IP}:${PORT}"
echo " Config:  ~/.litellm/config.yaml"
echo " Env:     ~/.litellm/.env (optional API keys)"
echo "========================================"
echo ""
echo "Usage:"
echo '  curl http://localhost:4000/v1/chat/completions \'
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\": \"llama3.1\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}]}'"
echo ""
echo "Press Ctrl+C to stop watching logs (container keeps running)."
echo ""

docker logs -f "$CONTAINER_NAME"
