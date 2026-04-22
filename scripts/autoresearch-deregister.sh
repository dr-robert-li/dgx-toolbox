#!/usr/bin/env bash
# autoresearch-deregister.sh — Remove a model from the sparkrun proxy.
#
# Usage: autoresearch-deregister.sh <model-name>
#   model-name: the model name registered with sparkrun proxy
#               (e.g., autoresearch/exp-20260324)
#
# Uses `sparkrun proxy unload` — removes the running workload and syncs the
# LiteLLM-backed sparkrun proxy via its management API. No proxy restart
# needed, no config-file editing.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <model-name>" >&2
  echo "" >&2
  echo "  model-name: sparkrun proxy model name to remove" >&2
  echo "  Example:    $0 autoresearch/exp-20260324" >&2
  exit 1
fi

MODEL_NAME="$1"

if ! command -v sparkrun >/dev/null 2>&1; then
  echo "ERROR: sparkrun not on PATH. Run setup/dgx-global-base-setup.sh." >&2
  exit 1
fi

# Confirm the model is currently registered before attempting unload.
if ! sparkrun proxy models 2>/dev/null | awk '{print $1}' | grep -qx "$MODEL_NAME"; then
  echo "Model not registered with sparkrun proxy: ${MODEL_NAME}" >&2
  echo "Current models:" >&2
  sparkrun proxy models 2>/dev/null | sed 's/^/  /' >&2 || true
  exit 1
fi

sparkrun proxy unload "$MODEL_NAME"
echo "Deregistered: ${MODEL_NAME}"
