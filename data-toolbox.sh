#!/usr/bin/env bash
# Interactive data-toolbox container with GPU access
# Mounts data directories from ~/data/
set -e

IMAGE="data-toolbox:latest"
CONTAINER_NAME="data-toolbox"

# Create host directories if needed
mkdir -p "$HOME/data/raw" "$HOME/data/processed" "$HOME/data/curated" "$HOME/data/synthetic" "$HOME/data/exports"

# If already running, exec into it
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Attaching to running data-toolbox container..."
    exec docker exec -it "$CONTAINER_NAME" bash
fi

docker rm -f "$CONTAINER_NAME" 2>/dev/null

exec docker run --gpus all -it --rm --ipc=host \
  --name "$CONTAINER_NAME" \
  --add-host=host.docker.internal:host-gateway \
  -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
  -v "$HOME/data/raw:/data/raw" \
  -v "$HOME/data/processed:/data/processed" \
  -v "$HOME/data/curated:/data/curated" \
  -v "$HOME/data/synthetic:/data/synthetic" \
  -v "$HOME/data/exports:/data/exports" \
  -v "$HOME/eval/models:/models:ro" \
  -v "${PWD}:/workspace" -w /workspace \
  "$IMAGE"
