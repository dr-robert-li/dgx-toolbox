#!/usr/bin/env bash
# n8n launcher with persistent storage
source "$(dirname "$0")/../lib.sh"
set -e

PORT=5678
CONTAINER_NAME="n8n"

create_n8n() {
  docker run -d \
    --name "$CONTAINER_NAME" \
    -p 0.0.0.0:${PORT}:${PORT} \
    -v ~/.n8n:/home/node/.n8n \
    --restart unless-stopped \
    n8nio/n8n
}

ensure_container "$CONTAINER_NAME" create_n8n
print_banner "n8n" "$PORT"
stream_logs "$CONTAINER_NAME"
