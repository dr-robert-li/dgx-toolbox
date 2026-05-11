#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
require_files "$SCRIPT_DIR/install-deps.py"
ensure_dirs "$HOME/.cache/huggingface" "$HOME/.cache/pip" "$HOME/unsloth-data"
# Launcher for NVIDIA Sync — starts container, returns immediately
# Sync handles auto-open via port config
PORT=8000
CONTAINER_NAME="unsloth-studio"

# Already running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Unsloth Studio is already running on port ${PORT}"
    exit 0
fi

docker rm -f "$CONTAINER_NAME" 2>/dev/null

docker run -d \
  --name "$CONTAINER_NAME" \
  --gpus all \
  --ipc=host \
  -p 0.0.0.0:${PORT}:${PORT} \
  -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
  -v "$HOME/.cache/pip:/root/.cache/pip" \
  -v "$HOME/unsloth-data:/workspace/work" \
  -v "$SCRIPT_DIR/install-deps.py:/tmp/install-deps.py:ro" \
  $(build_extra_mounts) \
  --restart unless-stopped \
  nvcr.io/nvidia/pytorch:25.11-py3 \
  bash -c '\
    python /tmp/install-deps.py unsloth unsloth_zoo && \
    pip uninstall -y torchcodec 2>/dev/null; \
    unsloth studio setup && \
    pip uninstall -y torchcodec 2>/dev/null; \
    unsloth studio -H 0.0.0.0 -p '"${PORT}"''

echo "Unsloth Studio starting on port ${PORT} (first launch may take up to 30 min)"
echo "Stream logs with: docker logs -f ${CONTAINER_NAME}"
