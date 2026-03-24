#!/usr/bin/env bash
# autoresearch-deregister.sh — Remove a model from LiteLLM config
#
# Usage: autoresearch-deregister.sh <model-name>
#   model-name: the LiteLLM model_name to remove (e.g., autoresearch/exp-20260324)
#
# WARNING: pyyaml does not preserve YAML comments. This command uses Python to
# remove the model entry; a timestamped backup is created before modification.
set -euo pipefail

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
if [ $# -ne 1 ]; then
  echo "Usage: $0 <model-name>" >&2
  echo "" >&2
  echo "  model-name: LiteLLM model_name to remove" >&2
  echo "  Example:    $0 autoresearch/exp-20260324" >&2
  exit 1
fi

MODEL_NAME="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LITELLM_CONFIG="${HOME}/.litellm/config.yaml"

# ---------------------------------------------------------------------------
# Validate config file exists
# ---------------------------------------------------------------------------
if [ ! -f "$LITELLM_CONFIG" ]; then
  echo "ERROR: LiteLLM config not found: ${LITELLM_CONFIG}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Check model exists in config
# ---------------------------------------------------------------------------
if ! grep -q "model_name: ${MODEL_NAME}" "$LITELLM_CONFIG" 2>/dev/null; then
  echo "Model not found in LiteLLM config: ${MODEL_NAME}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Remove model via Python helper (creates backup before modifying)
# ---------------------------------------------------------------------------
python3 "${SCRIPT_DIR}/_litellm_register.py" remove "$MODEL_NAME"

echo "Deregistered: ${MODEL_NAME}"
echo "Restart LiteLLM to apply: docker restart litellm"
