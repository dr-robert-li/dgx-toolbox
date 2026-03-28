#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
PORT=8888
IP=$(hostname -I | awk '{print $1}')

docker run --gpus all --rm --ipc=host \
  -p 0.0.0.0:${PORT}:${PORT} \
  -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
  -v "$HOME/requirements-gpu.txt:/tmp/requirements-gpu.txt" \
  -v "$HOME/ngc-quickstart.sh:/usr/local/bin/quickstart:ro" \
  -v "$HOME:/workspace" -w /workspace \
  $(build_extra_mounts) \
  nvcr.io/nvidia/pytorch:26.02-py3 \
  bash -c "pip install --no-deps -r /tmp/requirements-gpu.txt && jupyter lab --ip=0.0.0.0 --port=${PORT} --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password=''"
