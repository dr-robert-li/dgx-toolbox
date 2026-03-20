#!/usr/bin/env bash
# Argilla launcher with persistent storage
source "$(dirname "$0")/lib.sh"
set -e

PORT=6900
CONTAINER_NAME="argilla"

create_argilla() {
  docker run -d \
    --name "$CONTAINER_NAME" \
    -p 0.0.0.0:${PORT}:6900 \
    --restart unless-stopped \
    argilla/argilla-quickstart:latest
}

ensure_container "$CONTAINER_NAME" create_argilla
print_banner "Argilla" "$PORT"
echo ""
echo "Default credentials: argilla / 1234"
stream_logs "$CONTAINER_NAME"
