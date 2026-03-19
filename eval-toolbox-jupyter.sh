#!/usr/bin/env bash
# Jupyter Lab on the eval-toolbox image (port 8889 to avoid conflict with ngc-jupyter)
set -e

PORT=8889
IMAGE="eval-toolbox:latest"
IP=$(hostname -I | awk '{print $1}')

# Create host directories if needed
mkdir -p "$HOME/eval/datasets" "$HOME/eval/models" "$HOME/eval/runs"

echo "================================"
echo " Eval Toolbox — Jupyter Lab"
echo " Local:  http://localhost:${PORT}"
echo " LAN:    http://${IP}:${PORT}"
echo "================================"

exec docker run --gpus all --rm --ipc=host \
  -p 0.0.0.0:${PORT}:${PORT} \
  -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
  -v "$HOME/eval/datasets:/datasets" \
  -v "$HOME/eval/models:/models" \
  -v "$HOME/eval/runs:/eval_runs" \
  -v "$HOME:/workspace" -w /workspace \
  "$IMAGE" \
  -c "jupyter lab --ip=0.0.0.0 --port=${PORT} --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password=''"
