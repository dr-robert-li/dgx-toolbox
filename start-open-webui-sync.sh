#!/usr/bin/env bash
# Open-WebUI launcher for NVIDIA Sync — starts container, returns immediately
set -e

PORT=12000
CONTAINER_NAME="open-webui"
IMAGE="ghcr.io/open-webui/open-webui:ollama"

# Already running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Open-WebUI is already running on port ${PORT}"
    exit 0
fi

# Start existing stopped container
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
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
    "$IMAGE"

echo "Open-WebUI starting on port ${PORT}"
echo "Stream logs with: docker logs -f ${CONTAINER_NAME}"
