#!/usr/bin/env bash
PORT=8000
CONTAINER_NAME="unsloth-studio"

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
  -v "$HOME/unsloth-data:/workspace/work" \
  --restart unless-stopped \
  nvcr.io/nvidia/pytorch:25.11-py3 \
  bash -c '\
    pip install --no-deps unsloth unsloth_zoo && \
    python -c "
import importlib.metadata as md
from packaging.markers import Marker
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
    unsloth studio setup && \
    pip uninstall -y torchcodec 2>/dev/null; \
    unsloth studio -H 0.0.0.0 -p '"${PORT}"''

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
