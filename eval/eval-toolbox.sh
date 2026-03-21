#!/usr/bin/env bash
# Interactive eval-toolbox container with GPU access
# Mounts datasets, models, and eval_runs from ~/eval/
set -e

IMAGE="eval-toolbox:latest"
CONTAINER_NAME="eval-toolbox"

# Create host directories if needed
mkdir -p "$HOME/eval/datasets" "$HOME/eval/models" "$HOME/eval/runs"

# If already running, exec into it
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Attaching to running eval-toolbox container..."
    exec docker exec -it "$CONTAINER_NAME" bash
fi

docker rm -f "$CONTAINER_NAME" 2>/dev/null

exec docker run --gpus all -it --rm --ipc=host \
  --name "$CONTAINER_NAME" \
  --add-host=host.docker.internal:host-gateway \
  -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
  -v "$HOME/eval/datasets:/datasets" \
  -v "$HOME/eval/models:/models" \
  -v "$HOME/eval/runs:/eval_runs" \
  -v "$HOME/data/exports:/data/exports:ro" \
  -v "${PWD}:/workspace" -w /workspace \
  "$IMAGE"
