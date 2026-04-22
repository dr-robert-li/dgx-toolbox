#!/usr/bin/env bash
# Safety Harness gateway — proxies to the upstream OpenAI-compatible endpoint (sparkrun, :4000 by default) with auth, rate limiting, and trace logging
set -euo pipefail

HARNESS_PORT="${HARNESS_PORT:-5000}"
HARNESS_CONFIG_DIR="${HARNESS_CONFIG_DIR:-$(dirname "$0")/config}"
HARNESS_DATA_DIR="${HARNESS_DATA_DIR:-$(dirname "$0")/data}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export HARNESS_CONFIG_DIR HARNESS_DATA_DIR

echo "Starting DGX Safety Harness on :${HARNESS_PORT}"
echo "  Config: ${HARNESS_CONFIG_DIR}"
echo "  Data:   ${HARNESS_DATA_DIR}"
echo "  Upstream proxy: http://localhost:4000 (sparkrun — start with: sparkrun proxy start)"

cd "$SCRIPT_DIR"
exec uvicorn harness.main:app --host 0.0.0.0 --port "$HARNESS_PORT" --loop asyncio
