#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_dgx_sparkrun_wrappers.sh
. "$SCRIPT_DIR/_dgx_sparkrun_wrappers.sh"

host_args=()
_dgx_collect_host_args host_args "$@"

# Force LiteLLM's Anthropic passthrough (/v1/messages) to use /v1/chat/completions
# instead of the newer OpenAI Responses API (/v1/responses). 
# vLLM's Responses API is currently too strict for multi-turn validation.
export LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES=true

# Start the proxy
_dgx_exec_sparkrun proxy start "${host_args[@]}" "$@"

# Background sanitizer to fix Multi-turn / Validation errors
# Periodically ensures all models have: 1. openai/ prefix, 2. drop_params: true
(
  # Give proxy time to boot
  sleep 5
  while true; do
    # If proxy is gone, exit sanitizer
    if ! sparkrun proxy status >/dev/null 2>&1; then break; fi
    # Apply fixes via Management API
    _dgx_fix_litellm_models >/dev/null 2>&1 || true
    sleep 30
  done
) >/dev/null 2>&1 &
disown
