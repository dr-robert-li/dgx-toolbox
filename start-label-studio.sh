#!/usr/bin/env bash
# Label Studio launcher with persistent storage
source "$(dirname "$0")/lib.sh"
set -e

PORT=8081
CONTAINER_NAME="label-studio"

ensure_dirs "$HOME/label-studio-data"
chmod 777 "$HOME/label-studio-data"

create_label_studio() {
  docker run -d \
    --name "$CONTAINER_NAME" \
    -p 0.0.0.0:${PORT}:8080 \
    -v "$HOME/label-studio-data:/label-studio/data" \
    --restart unless-stopped \
    heartexlabs/label-studio:latest
}

ensure_container "$CONTAINER_NAME" create_label_studio
print_banner "Label Studio" "$PORT" "Data:   ~/label-studio-data"
stream_logs "$CONTAINER_NAME"
