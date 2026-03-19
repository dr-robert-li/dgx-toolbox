#!/usr/bin/env bash
# Argilla launcher with persistent storage
set -e

PORT=6900
CONTAINER_NAME="argilla"
IMAGE="argilla/argilla-quickstart:latest"
IP=$(hostname -I | awk '{print $1}')

# Check if container already exists
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "Argilla is already running"
    else
        echo "Starting existing Argilla container..."
        docker start "$CONTAINER_NAME"
    fi
else
    echo "Creating Argilla container..."
    docker run -d \
        --name "$CONTAINER_NAME" \
        -p 0.0.0.0:${PORT}:6900 \
        --restart unless-stopped \
        "$IMAGE"
fi

echo ""
echo "========================================"
echo " Argilla"
echo " Local:  http://localhost:${PORT}"
echo " LAN:    http://${IP}:${PORT}"
echo "========================================"
echo ""
echo "Default credentials: argilla / 1234"
echo ""
echo "If using NVIDIA Sync, access via your forwarded local port."
echo "Press Ctrl+C to stop watching logs (container keeps running)."
echo ""

docker logs -f "$CONTAINER_NAME"
