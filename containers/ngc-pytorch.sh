#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
docker run --gpus all -it --rm --ipc=host \
  -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
  -v "$HOME/requirements-gpu.txt:/tmp/requirements-gpu.txt" \
  -v "$HOME/ngc-quickstart.sh:/usr/local/bin/quickstart:ro" \
  -v "${PWD}:/workspace" -w /workspace \
  $(build_extra_mounts) \
  nvcr.io/nvidia/pytorch:26.02-py3 \
  bash -c "pip install --no-deps -r /tmp/requirements-gpu.txt && quickstart && exec bash"
