#!/usr/bin/env bash
# Open-WebUI launcher for NVIDIA Sync — returns immediately
source "$(dirname "$0")/../lib.sh"
set -e

PORT=12000
CONTAINER_NAME="open-webui"

if is_running "$CONTAINER_NAME"; then
  echo "Open-WebUI is already running on port ${PORT}"
  exit 0
fi

if container_exists "$CONTAINER_NAME"; then
  docker start "$CONTAINER_NAME"
  echo "Open-WebUI started on port ${PORT}"
  exit 0
fi

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

sync_exit "$CONTAINER_NAME" "$PORT"
