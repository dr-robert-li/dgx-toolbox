#!/usr/bin/env bash
# Triton Inference Server with TensorRT-LLM backend
# Exposes HTTP :8010, gRPC :8011, metrics :8012
# (offset from default 8000-8002 to avoid conflict with Unsloth Studio)
set -e

CONTAINER_NAME="triton-trtllm"
IMAGE="nvcr.io/nvidia/tritonserver:26.02-trtllm-python-py3"
HTTP_PORT=8010
GRPC_PORT=8011
METRICS_PORT=8012
IP=$(hostname -I | awk '{print $1}')

# Create host directories if needed
mkdir -p "$HOME/triton/engines" "$HOME/triton/model_repo"

# Already running — show status and attach logs
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Triton TRT-LLM is already running"
    echo "  HTTP:    http://${IP}:${HTTP_PORT}"
    echo "  gRPC:    ${IP}:${GRPC_PORT}"
    echo "  Metrics: http://${IP}:${METRICS_PORT}/metrics"
    echo ""
    echo "Streaming logs (Ctrl+C to detach)..."
    exec docker logs -f "$CONTAINER_NAME"
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
    echo "No models in /triton_model_repo — starting shell. Populate ~/triton/model_repo on host and restart."; \
    sleep infinity; \
  fi'

echo ""
echo "============================================"
echo " Triton TRT-LLM Server"
echo "============================================"
echo "  HTTP:    http://localhost:${HTTP_PORT}"
echo "  gRPC:    localhost:${GRPC_PORT}"
echo "  Metrics: http://localhost:${METRICS_PORT}/metrics"
echo "  LAN:     http://${IP}:${HTTP_PORT}"
echo ""
echo "  Engines:    ~/triton/engines"
echo "  Model repo: ~/triton/model_repo"
echo "============================================"
echo ""
echo "Streaming logs (Ctrl+C to detach, container keeps running)..."
docker logs -f "$CONTAINER_NAME"
