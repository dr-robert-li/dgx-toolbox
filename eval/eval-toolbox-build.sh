#!/usr/bin/env bash
# Build the eval-toolbox Docker image (builds base-toolbox first if needed)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TAG="${1:-latest}"

# Ensure base image exists
if ! docker image inspect "base-toolbox:${TAG}" &>/dev/null; then
  echo "Base image not found — building base-toolbox:${TAG} first..."
  docker build -t "base-toolbox:${TAG}" "${SCRIPT_DIR}/base-toolbox"
  echo ""
fi

echo "Building eval-toolbox:${TAG} ..."
docker build -t "eval-toolbox:${TAG}" "${SCRIPT_DIR}/eval-toolbox"
echo ""
echo "Done. Image: eval-toolbox:${TAG}"
echo "Run with: eval-toolbox  (or ~/dgx-toolbox/eval-toolbox.sh)"
