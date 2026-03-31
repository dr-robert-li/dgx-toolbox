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
CONTAINER_NAME="unsloth-headless"

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
echo "================================================"
echo ""

docker run -d \
  --name "$CONTAINER_NAME" \
  --gpus all \
  --ipc=host \
  -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
  -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
  -v "$HOME/unsloth-data:/workspace/work" \
  $(build_extra_mounts) \
  --restart unless-stopped \
  nvcr.io/nvidia/pytorch:25.11-py3 \
  bash -c '\
    pip install --no-deps unsloth unsloth_zoo && \
    python -c "
import importlib.metadata as md
from packaging.requirements import Requirement
seen = set()
missing = []
for pkg in [\"unsloth\", \"unsloth_zoo\"]:
    for r in (md.requires(pkg) or []):
        req = Requirement(r)
        if req.extras: continue
        if req.marker and not req.marker.evaluate(): continue
        if req.name in seen: continue
        seen.add(req.name)
        try: md.distribution(req.name)
        except md.PackageNotFoundError: missing.append(str(req))
if missing:
    print(\"Missing deps: \" + \", \".join(missing))
    with open(\"/tmp/missing_deps.txt\", \"w\") as f: f.write(chr(10).join(missing))
else:
    print(\"All deps satisfied\")
    open(\"/tmp/missing_deps.txt\", \"w\").close()
" && \
    if [ -s /tmp/missing_deps.txt ]; then pip install --no-build-isolation -r /tmp/missing_deps.txt; fi && \
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
