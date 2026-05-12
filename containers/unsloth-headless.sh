#!/usr/bin/env bash
# Headless Unsloth container for autonomous training pipelines.
#
# Unlike unsloth-studio.sh, this does NOT start the Studio web UI.
# The container stays alive via 'sleep infinity' and is used exclusively
# through 'docker exec' — ideal for dgx_toolbox.py automation.
#
# Usage:
#   unsloth-headless                              # Interactive (streams logs)
#   EXTRA_MOUNTS="$HOME/project:/workspace/project" unsloth-headless
#
# The container installs unsloth + deps on first start, then idles.
# All training commands run via: docker exec unsloth-headless python ...

source "$(dirname "$0")/../lib.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
require_files "$SCRIPT_DIR/install-deps.py"
ensure_dirs "$HOME/.cache/huggingface" "$HOME/.cache/pip" "$HOME/unsloth-data"
CONTAINER_NAME="unsloth-headless"

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
if is_running "$CONTAINER_NAME"; then
    echo "Unsloth headless container is already running"
    echo "  Exec into it: docker exec -it $CONTAINER_NAME bash"
    exit 0
fi

# Remove stopped container if exists
docker rm -f "$CONTAINER_NAME" 2>/dev/null

echo ""
echo "================================================"
echo "  Unsloth Headless (Training)"
echo "================================================"
echo ""
echo "  Container: $CONTAINER_NAME"
echo "  Exec:      docker exec -it $CONTAINER_NAME bash"
echo "  Stop:      docker stop $CONTAINER_NAME"
if [ -n "$HF_PINS_ARG" ]; then
    echo "  HF pins:   $HF_PINS_FILE"
fi
echo "================================================"
echo ""

docker run -d \
  --name "$CONTAINER_NAME" \
  --gpus all \
  --ipc=host \
  -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
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
    echo "Unsloth headless ready — waiting for exec commands..." && \
    sleep infinity'

echo "Container starting (deps install takes ~60s)..."
echo "Stream logs with: docker logs -f $CONTAINER_NAME"
echo ""

# Wait for deps to finish, then confirm ready
(
    for i in $(seq 1 120); do
        if ! is_running "$CONTAINER_NAME"; then
            echo "Container exited unexpectedly."
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
            exit 1
        fi
        if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "waiting for exec commands"; then
            echo "Unsloth headless is ready."
            exit 0
        fi
        sleep 5
    done
    echo "Setup did not complete within 10 minutes."
) &

exec docker logs -f "$CONTAINER_NAME" 2>&1
