#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
require_files "$SCRIPT_DIR/install-deps.py"
ensure_dirs "$HOME/.cache/huggingface" "$HOME/.cache/pip" "$HOME/unsloth-data"
PORT=8000
CONTAINER_NAME="unsloth-studio"

# Optional version pin (e.g. UNSLOTH_VERSION=2026.3.5) — empty means latest.
UNSLOTH_VERSION="${UNSLOTH_VERSION:-}"
if [ -n "$UNSLOTH_VERSION" ]; then
    UNSLOTH_SPEC="unsloth==${UNSLOTH_VERSION} unsloth_zoo==${UNSLOTH_VERSION}"
else
    UNSLOTH_SPEC="unsloth unsloth_zoo"
fi

# Check if already running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    IP=$(hostname -I | awk '{print $1}')
    echo "Unsloth Studio is already running"
    echo "  Studio:  http://localhost:${PORT}"
    echo "  LAN:     http://${IP}:${PORT}"
    xdg-open "http://localhost:${PORT}" 2>/dev/null || true
    exit 0
fi

# Remove stopped container if exists
docker rm -f "$CONTAINER_NAME" 2>/dev/null

IP=$(hostname -I | awk '{print $1}')
echo ""
echo "================================================"
echo "  Unsloth Studio"
echo "================================================"
echo ""
echo "  Studio:   http://localhost:${PORT}"
echo "  LAN:      http://${IP}:${PORT}"
echo ""
echo "  Data dir: ~/unsloth-data"
echo "  Stop:     unsloth-stop"
echo "================================================"
echo ""

docker run -d \
  --name "$CONTAINER_NAME" \
  --gpus all \
  --ipc=host \
  -p 0.0.0.0:${PORT}:${PORT} \
  -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
  -v "$HOME/.cache/pip:/root/.cache/pip" \
  -v "$HOME/unsloth-data:/workspace/work" \
  -v "${PWD}:/workspace/project" \
  -v "$SCRIPT_DIR/install-deps.py:/tmp/install-deps.py:ro" \
  $(build_extra_mounts) \
  --restart unless-stopped \
  nvcr.io/nvidia/pytorch:25.11-py3 \
  bash -c '\
    python /tmp/install-deps.py '"${UNSLOTH_SPEC}"' && \
    pip uninstall -y torchcodec 2>/dev/null; \
    (unsloth studio setup && \
     pip uninstall -y torchcodec 2>/dev/null; \
     unsloth studio -H 0.0.0.0 -p '"${PORT}"') || \
    { echo "ERROR: unsloth studio setup/start failed — keeping container alive for inspection"; sleep infinity; }'

# Poll for readiness in the background, open browser when ready
(
    for i in $(seq 1 360); do
        if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            echo ""
            echo "Container exited unexpectedly."
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
            exit 1
        fi
        # Container kept alive after a bringup failure (see inner cmd's `|| { ... sleep infinity; }`).
        # Without this short-circuit the poll would hang the full 30 minutes.
        if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "ERROR: unsloth studio setup/start failed"; then
            echo ""
            echo "Studio bringup failed. Container left running for inspection."
            echo "  docker logs $CONTAINER_NAME"
            echo "  docker exec -it $CONTAINER_NAME bash"
            echo "  Stop with: docker stop $CONTAINER_NAME"
            echo ""
            echo "--- last 20 log lines ---"
            docker logs --tail 20 "$CONTAINER_NAME" 2>&1
            exit 1
        fi
        if curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT}" 2>/dev/null | grep -q "200\|302\|301"; then
            echo ""
            echo "Unsloth Studio is ready!"
            xdg-open "http://localhost:${PORT}" 2>/dev/null || true
            exit 0
        fi
        sleep 5
    done
    echo ""
    echo "Studio did not respond within 30 minutes."
) &

# Stream container logs until stopped (Ctrl+C to detach)
exec docker logs -f "$CONTAINER_NAME" 2>&1
