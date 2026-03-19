#!/usr/bin/env bash
# Jupyter Lab on the data-toolbox image (port 8890)
set -e

PORT=8890
IMAGE="data-toolbox:latest"
IP=$(hostname -I | awk '{print $1}')

# Create host directories if needed
mkdir -p "$HOME/data/raw" "$HOME/data/processed" "$HOME/data/curated" "$HOME/data/synthetic" "$HOME/data/exports"

echo "================================"
echo " Data Toolbox — Jupyter Lab"
echo " Local:  http://localhost:${PORT}"
echo " LAN:    http://${IP}:${PORT}"
echo "================================"

exec docker run --gpus all --rm --ipc=host \
  -p 0.0.0.0:${PORT}:${PORT} \
  -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
  -v "$HOME/data/raw:/data/raw" \
  -v "$HOME/data/processed:/data/processed" \
  -v "$HOME/data/curated:/data/curated" \
  -v "$HOME/data/synthetic:/data/synthetic" \
  -v "$HOME/data/exports:/data/exports" \
  -v "$HOME:/workspace" -w /workspace \
  "$IMAGE" \
  -c "jupyter lab --ip=0.0.0.0 --port=${PORT} --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password=''"
