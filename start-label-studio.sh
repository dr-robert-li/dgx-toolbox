#!/usr/bin/env bash
# Label Studio launcher with persistent storage
set -e

PORT=8081
CONTAINER_NAME="label-studio"
IMAGE="heartexlabs/label-studio:latest"
IP=$(hostname -I | awk '{print $1}')

mkdir -p "$HOME/label-studio-data"
chmod 777 "$HOME/label-studio-data"

# Check if container already exists
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "Label Studio is already running"
    else
        echo "Starting existing Label Studio container..."
        docker start "$CONTAINER_NAME"
    fi
else
    echo "Creating Label Studio container..."
    docker run -d \
        --name "$CONTAINER_NAME" \
        -p 0.0.0.0:${PORT}:8080 \
        -v "$HOME/label-studio-data:/label-studio/data" \
        --restart unless-stopped \
        "$IMAGE"
fi

echo ""
echo "========================================"
echo " Label Studio"
echo " Local:  http://localhost:${PORT}"
echo " LAN:    http://${IP}:${PORT}"
echo " Data:   ~/label-studio-data"
echo "========================================"
echo ""
echo "If using NVIDIA Sync, access via your forwarded local port."
echo "Press Ctrl+C to stop watching logs (container keeps running)."
echo ""

docker logs -f "$CONTAINER_NAME"
