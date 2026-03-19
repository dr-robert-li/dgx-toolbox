#!/usr/bin/env bash
# Open-WebUI launcher with Ollama backend and persistent storage
set -e

PORT=12000
CONTAINER_NAME="open-webui"
IMAGE="ghcr.io/open-webui/open-webui:ollama"
IP=$(hostname -I | awk '{print $1}')

# Check if container already exists
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "Open-WebUI is already running"
    else
        echo "Starting existing Open-WebUI container..."
        docker start "$CONTAINER_NAME"
    fi
else
    echo "Creating Open-WebUI container..."
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
fi

echo ""
echo "========================================"
echo " Open-WebUI"
echo " Local:  http://localhost:${PORT}"
echo " LAN:    http://${IP}:${PORT}"
echo "========================================"
echo ""
echo "If using NVIDIA Sync, access via your forwarded local port."
echo "Press Ctrl+C to stop watching logs (container keeps running)."
echo ""

docker logs -f "$CONTAINER_NAME"
