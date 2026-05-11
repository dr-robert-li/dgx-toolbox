#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
require_files "$HOME/ngc-quickstart.sh" "$HOME/requirements-gpu.txt" "$SCRIPT_DIR/install-deps.py"
ensure_dirs "$HOME/.cache/huggingface" "$HOME/.cache/pip"
PORT=8888
IP=$(hostname -I | awk '{print $1}')

docker run --gpus all --rm --ipc=host \
  -p 0.0.0.0:${PORT}:${PORT} \
  -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
  -v "$HOME/.cache/pip:/root/.cache/pip" \
  -v "$HOME/requirements-gpu.txt:/tmp/requirements-gpu.txt" \
  -v "$HOME/ngc-quickstart.sh:/usr/local/bin/quickstart:ro" \
  -v "$SCRIPT_DIR/install-deps.py:/tmp/install-deps.py:ro" \
  -v "$HOME:/workspace" -w /workspace \
  $(build_extra_mounts) \
  nvcr.io/nvidia/pytorch:26.02-py3 \
  bash -c "python /tmp/install-deps.py -r /tmp/requirements-gpu.txt && pip uninstall -y torchcodec 2>/dev/null; jupyter lab --ip=0.0.0.0 --port=${PORT} --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password=''"
