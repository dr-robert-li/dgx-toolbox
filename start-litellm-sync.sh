#!/usr/bin/env bash
# LiteLLM launcher for NVIDIA Sync — starts proxy, returns immediately
set -e

PORT=4000
CONTAINER_NAME="litellm"
IMAGE="ghcr.io/berriai/litellm:main-latest"
CONFIG_DIR="$HOME/.litellm"

mkdir -p "$CONFIG_DIR"

# Create default config if not present
if [ ! -f "$CONFIG_DIR/config.yaml" ]; then
    cat > "$CONFIG_DIR/config.yaml" << 'YAML'
model_list:
  - model_name: llama3.1
    litellm_params:
      model: ollama/llama3.1
      api_base: http://host.docker.internal:11434
  - model_name: gemma3
    litellm_params:
      model: ollama/gemma3
      api_base: http://host.docker.internal:11434

litellm_settings:
  drop_params: true
  set_verbose: false
YAML
fi

# Already running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "LiteLLM is already running on port ${PORT}"
    exit 0
fi

# Start existing stopped container
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    docker start "$CONTAINER_NAME"
    echo "LiteLLM started on port ${PORT}"
    exit 0
fi

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

echo "LiteLLM starting on port ${PORT}"
echo "Stream logs with: docker logs -f ${CONTAINER_NAME}"
