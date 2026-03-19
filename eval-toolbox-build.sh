#!/usr/bin/env bash
# Build the eval-toolbox Docker image
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="eval-toolbox"
TAG="${1:-latest}"

echo "Building ${IMAGE_NAME}:${TAG} ..."
docker build -t "${IMAGE_NAME}:${TAG}" "${SCRIPT_DIR}/eval-toolbox"
echo ""
echo "Done. Image: ${IMAGE_NAME}:${TAG}"
echo "Run with: eval-toolbox  (or ~/dgx-toolbox/eval-toolbox.sh)"
