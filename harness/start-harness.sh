#!/usr/bin/env bash
# Safety Harness gateway — proxies to the upstream OpenAI-compatible endpoint (sparkrun, :4000 by default) with auth, rate limiting, and trace logging
set -euo pipefail

HARNESS_PORT="${HARNESS_PORT:-5000}"
HARNESS_CONFIG_DIR="${HARNESS_CONFIG_DIR:-$(dirname "$0")/config}"
HARNESS_DATA_DIR="${HARNESS_DATA_DIR:-$(dirname "$0")/data}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_VENV="${HARNESS_VENV:-$HOME/.dgx-harness/venv}"

export HARNESS_CONFIG_DIR HARNESS_DATA_DIR

echo "Starting DGX Safety Harness on :${HARNESS_PORT}"
echo "  Config: ${HARNESS_CONFIG_DIR}"
echo "  Data:   ${HARNESS_DATA_DIR}"
echo "  Venv:   ${HARNESS_VENV}"
echo "  Upstream proxy: http://localhost:4000 (sparkrun — start with: sparkrun proxy start)"

# Prefer the dedicated harness venv created by setup/dgx-global-base-setup.sh.
# Falls back to whatever uvicorn is on PATH if the venv doesn't exist yet
# (e.g. someone running from a dev machine that hasn't been bootstrapped).
if [ -x "$HARNESS_VENV/bin/uvicorn" ]; then
  UVICORN="$HARNESS_VENV/bin/uvicorn"
elif command -v uvicorn >/dev/null 2>&1; then
  echo "  (warning) dedicated harness venv not found at $HARNESS_VENV — using system uvicorn"
  UVICORN="$(command -v uvicorn)"
else
  echo "Error: uvicorn not found. Run: bash setup/dgx-global-base-setup.sh" >&2
  exit 1
fi

cd "$SCRIPT_DIR"
exec "$UVICORN" harness.main:app --host 0.0.0.0 --port "$HARNESS_PORT" --loop asyncio
