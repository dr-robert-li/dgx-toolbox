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

# Optional HF-stack pin file (transformers / tokenizers / hub / peft / trl / bnb).
# Defaults to $HOME/requirements-gpu.txt — the same path NGC launchers honour.
# Override with HF_PINS_FILE=/abs/path or HF_PINS_FILE='' to disable.
HF_PINS_FILE="${HF_PINS_FILE-$HOME/requirements-gpu.txt}"
HF_PINS_MOUNT=""
HF_PINS_ARG=""
if [ -n "$HF_PINS_FILE" ] && [ -f "$HF_PINS_FILE" ]; then
    HF_PINS_MOUNT="-v $HF_PINS_FILE:/tmp/requirements-gpu.txt:ro"
    HF_PINS_ARG="-r /tmp/requirements-gpu.txt"
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
if [ -n "$HF_PINS_ARG" ]; then
    echo "  HF pins:  $HF_PINS_FILE"
fi
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
  $HF_PINS_MOUNT \
  $(build_extra_mounts) \
  --restart unless-stopped \
  nvcr.io/nvidia/pytorch:25.11-py3 \
  bash -c '\
    python /tmp/install-deps.py '"${HF_PINS_ARG}"' '"${UNSLOTH_SPEC}"' && \
    pip uninstall -y torchcodec 2>/dev/null; \
    VENV=/root/.unsloth/studio/unsloth_studio; \
    if [ ! -x "$VENV/bin/python" ]; then \
        echo "[unsloth-studio] venv missing at $VENV; bootstrapping via install.sh"; \
        curl -fsSL https://unsloth.ai/install.sh | sh || true; \
    fi; \
    if [ "$(uname -m)" = "aarch64" ] && [ -x "$VENV/bin/python" ]; then \
        echo "[unsloth-studio] aarch64 host detected; overriding torchcodec pin in venv"; \
        "$VENV/bin/python" -m pip uninstall -y torchcodec 2>/dev/null; \
        "$VENV/bin/python" -m pip install --no-deps "torchcodec>=0.11,<0.12" || \
            echo "[unsloth-studio] WARN: torchcodec>=0.11 install failed; studio may still run without video support"; \
    fi; \
    if [ ! -x "$VENV/bin/unsloth" ]; then \
        echo "[unsloth-studio] FATAL: venv bootstrap incomplete — $VENV/bin/unsloth not found"; \
        echo "[unsloth-studio] Inspect curl install.sh output above for resolver errors"; \
        exit 1; \
    fi && \
    "$VENV/bin/unsloth" studio setup && \
    "$VENV/bin/unsloth" studio -H 0.0.0.0 -p '"${PORT}"''

# Poll for readiness in the background, open browser when ready
(
    for i in $(seq 1 360); do
        if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            echo ""
            echo "Container exited unexpectedly."
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
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
