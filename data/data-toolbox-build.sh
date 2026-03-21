#!/usr/bin/env bash
# Build the data-toolbox Docker image (builds base-toolbox first if needed)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TAG="${1:-latest}"

# Ensure base image exists
if ! docker image inspect "base-toolbox:${TAG}" &>/dev/null; then
  echo "Base image not found — building base-toolbox:${TAG} first..."
  docker build -t "base-toolbox:${TAG}" "${SCRIPT_DIR}/base-toolbox"
  echo ""
fi

echo "Building data-toolbox:${TAG} ..."
docker build -t "data-toolbox:${TAG}" "${SCRIPT_DIR}/data-toolbox"
echo ""
echo "Done. Image: data-toolbox:${TAG}"
echo "Run with: data-toolbox  (or ~/dgx-toolbox/data-toolbox.sh)"
