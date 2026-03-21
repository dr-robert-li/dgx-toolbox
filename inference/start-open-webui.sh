#!/usr/bin/env bash
# Open-WebUI launcher with Ollama backend and persistent storage
source "$(dirname "$0")/../lib.sh"
set -e

PORT=12000
CONTAINER_NAME="open-webui"

create_open_webui() {
  docker run -d \
    --name "$CONTAINER_NAME" \
    --gpus all \
    -p 0.0.0.0:${PORT}:8080 \
    -v open-webui:/app/backend/data \
    -v open-webui-ollama:/root/.ollama \
    -e SCARF_NO_ANALYTICS=true \
    -e DO_NOT_TRACK=true \
    -e ANONYMIZED_TELEMETRY=false \
    --restart unless-stopped \
    ghcr.io/open-webui/open-webui:ollama
}

ensure_container "$CONTAINER_NAME" create_open_webui
print_banner "Open-WebUI" "$PORT"
stream_logs "$CONTAINER_NAME"
