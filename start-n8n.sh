#!/bin/bash
# n8n launcher for NVIDIA Sync
# Sync will forward the port specified below to your local machine

PORT=5678
IP=$(hostname -I | awk '{print $1}')
CONTAINER_NAME="n8n"

# Check if container already exists
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "n8n is already running"
    else
        echo "Starting existing n8n container..."
        docker start "$CONTAINER_NAME"
    fi
else
    echo "Creating n8n container..."
    docker run -d \
        --name "$CONTAINER_NAME" \
        -p 0.0.0.0:${PORT}:${PORT} \
        -v ~/.n8n:/home/node/.n8n \
        --restart unless-stopped \
        n8nio/n8n
fi

echo ""
echo "================================"
echo " n8n is running!"
echo " Local:  http://localhost:${PORT}"
echo " LAN:    http://${IP}:${PORT}"
echo "================================"
echo ""
echo "If using NVIDIA Sync, access via your forwarded local port."
echo "Press Ctrl+C to stop watching logs (container keeps running)."
echo ""

docker logs -f "$CONTAINER_NAME"
