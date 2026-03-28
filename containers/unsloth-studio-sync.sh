#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
# Launcher for NVIDIA Sync — starts container, returns immediately
# Sync handles auto-open via port config
PORT=8000
CONTAINER_NAME="unsloth-studio"

# Already running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Unsloth Studio is already running on port ${PORT}"
    exit 0
fi

docker rm -f "$CONTAINER_NAME" 2>/dev/null

docker run -d \
  --name "$CONTAINER_NAME" \
  --gpus all \
  --ipc=host \
  -p 0.0.0.0:${PORT}:${PORT} \
  -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
  -v "$HOME/unsloth-data:/workspace/work" \
  $(build_extra_mounts) \
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

echo "Unsloth Studio starting on port ${PORT} (first launch may take up to 30 min)"
echo "Stream logs with: docker logs -f ${CONTAINER_NAME}"
