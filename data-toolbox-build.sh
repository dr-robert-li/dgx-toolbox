#!/usr/bin/env bash
# Build the data-toolbox Docker image
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="data-toolbox"
TAG="${1:-latest}"

echo "Building ${IMAGE_NAME}:${TAG} ..."
docker build -t "${IMAGE_NAME}:${TAG}" "${SCRIPT_DIR}/data-toolbox"
echo ""
echo "Done. Image: ${IMAGE_NAME}:${TAG}"
echo "Run with: data-toolbox  (or ~/dgx-toolbox/data-toolbox.sh)"
