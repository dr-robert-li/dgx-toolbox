#!/usr/bin/env bash
# Build all toolbox Docker images (base → eval + data)
# Usage: build-toolboxes.sh [tag]
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TAG="${1:-latest}"

echo "=== Building base-toolbox:${TAG} ==="
docker build -t "base-toolbox:${TAG}" "${SCRIPT_DIR}/base-toolbox"

echo ""
echo "=== Building eval-toolbox:${TAG} (from base-toolbox) ==="
docker build -t "eval-toolbox:${TAG}" "${SCRIPT_DIR}/eval-toolbox"

echo ""
echo "=== Building data-toolbox:${TAG} (from base-toolbox) ==="
docker build -t "data-toolbox:${TAG}" "${SCRIPT_DIR}/data-toolbox"

echo ""
echo "Done. Images built:"
echo "  base-toolbox:${TAG}"
echo "  eval-toolbox:${TAG}"
echo "  data-toolbox:${TAG}"
