#!/usr/bin/env bash
# Triton TRT-LLM launcher for NVIDIA Sync — starts container, returns immediately
set -e

CONTAINER_NAME="triton-trtllm"
IMAGE="nvcr.io/nvidia/tritonserver:26.02-trtllm-python-py3"
HTTP_PORT=8010
GRPC_PORT=8011
METRICS_PORT=8012

# Create host directories if needed
mkdir -p "$HOME/triton/engines" "$HOME/triton/model_repo"

# Already running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Triton TRT-LLM is already running on ports ${HTTP_PORT}/${GRPC_PORT}/${METRICS_PORT}"
    exit 0
fi

docker rm -f "$CONTAINER_NAME" 2>/dev/null

docker run -d \
  --name "$CONTAINER_NAME" \
  --gpus all \
  --shm-size=2g \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  -p 0.0.0.0:${HTTP_PORT}:8000 \
  -p 0.0.0.0:${GRPC_PORT}:8001 \
  -p 0.0.0.0:${METRICS_PORT}:8002 \
  -v "$HOME/triton/engines:/engines" \
  -v "$HOME/triton/model_repo:/triton_model_repo" \
  --restart unless-stopped \
  "$IMAGE" \
  bash -c 'if [ -d /triton_model_repo ] && [ "$(ls -A /triton_model_repo 2>/dev/null)" ]; then \
    tritonserver --model-repository=/triton_model_repo; \
  else \
    echo "No models in /triton_model_repo — waiting. Populate ~/triton/model_repo on host and restart."; \
    sleep infinity; \
  fi'

echo "Triton TRT-LLM starting on ports ${HTTP_PORT}/${GRPC_PORT}/${METRICS_PORT}"
echo "Stream logs with: docker logs -f ${CONTAINER_NAME}"
