#!/usr/bin/env bash
# Headless Unsloth container — sync variant (returns immediately).
# See unsloth-headless.sh for details.

source "$(dirname "$0")/../lib.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
require_files "$SCRIPT_DIR/install-deps.py"
ensure_dirs "$HOME/.cache/huggingface" "$HOME/.cache/pip" "$HOME/unsloth-data"
CONTAINER_NAME="unsloth-headless"

if is_running "$CONTAINER_NAME"; then
    echo "Unsloth headless container is already running"
    exit 0
fi

docker rm -f "$CONTAINER_NAME" 2>/dev/null

docker run -d \
  --name "$CONTAINER_NAME" \
  --gpus all \
  --ipc=host \
  -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
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
    echo "Unsloth headless ready — waiting for exec commands..." && \
    sleep infinity'

sync_exit "$CONTAINER_NAME" "N/A (headless)"
