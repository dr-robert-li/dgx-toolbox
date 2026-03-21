#!/usr/bin/env bash
# modelstore/cmd/recall.sh — Synchronous recall of a model from cold to hot storage
# Usage: recall.sh <model_path> [--trigger=manual|auto|cron]
# Moves a cold-stored model (symlink) back to hot storage and resets the usage timer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/config.sh
source "${SCRIPT_DIR}/../lib/config.sh"
# shellcheck source=../lib/hf_adapter.sh
source "${SCRIPT_DIR}/../lib/hf_adapter.sh"
# shellcheck source=../lib/ollama_adapter.sh
source "${SCRIPT_DIR}/../lib/ollama_adapter.sh"
# shellcheck source=../lib/audit.sh
source "${SCRIPT_DIR}/../lib/audit.sh"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

MODEL_PATH="${1:?Usage: recall.sh <model_path>}"
TRIGGER="manual"

for arg in "${@:2}"; do
  [[ "$arg" == "--trigger=auto" ]]   && TRIGGER="auto"
  [[ "$arg" == "--trigger=cron" ]]   && TRIGGER="cron"
  [[ "$arg" == "--trigger=manual" ]] && TRIGGER="manual"
done

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------

load_config
# Sets: HOT_HF_PATH, HOT_OLLAMA_PATH, COLD_PATH, RETENTION_DAYS, CRON_HOUR

OP_STATE_FILE="${HOME}/.modelstore/op_state.json"
USAGE_FILE="${HOME}/.modelstore/usage.json"

# ---------------------------------------------------------------------------
# State file helpers (interrupt-safe operations — SAFE-05)
# ---------------------------------------------------------------------------

_write_op_state() {
  local op="$1" model="$2" phase="$3" trigger="$4"
  jq -cn \
    --arg op "$op" \
    --arg m "$model" \
    --arg ph "$phase" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg tr "$trigger" \
    '{op:$op, model:$m, phase:$ph, started_at:$ts, trigger:$tr}' \
    > "${OP_STATE_FILE}.tmp"
  mv "${OP_STATE_FILE}.tmp" "$OP_STATE_FILE"
}

_clear_op_state() {
  rm -f "$OP_STATE_FILE"
}

# ---------------------------------------------------------------------------
# Stale state check: clear op_state.json if older than 4 hours
# ---------------------------------------------------------------------------

if [[ -f "$OP_STATE_FILE" ]]; then
  op_started_at=$(jq -r '.started_at // empty' "$OP_STATE_FILE" 2>/dev/null || true)
  if [[ -n "$op_started_at" ]]; then
    op_epoch=$(date -d "$op_started_at" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    age_sec=$(( now_epoch - op_epoch ))
    if [[ "$age_sec" -gt 14400 ]]; then
      ms_log "WARNING: Clearing stale operation state (started at ${op_started_at})"
      _clear_op_state
    else
      ms_log "Resuming interrupted operation (started at ${op_started_at})"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Auto-trigger guard: skip if model files are in use (fuser check)
# Prevents recalling a model that vLLM or another process is actively reading
# ---------------------------------------------------------------------------

if [[ "$TRIGGER" == "auto" ]]; then
  if fuser -s "$MODEL_PATH" 2>/dev/null; then
    ms_log "Model in use, skipping auto-recall: $MODEL_PATH"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Verify model_path is a symlink (indicates it was previously migrated to cold)
# ---------------------------------------------------------------------------

if [[ ! -L "$MODEL_PATH" ]]; then
  ms_log "Not a symlink, skip recall: $MODEL_PATH"
  exit 0
fi

# ---------------------------------------------------------------------------
# Execute recall
# ---------------------------------------------------------------------------

start_epoch=$(date +%s)

# Write state before starting multi-step operation
_write_op_state "recall" "$MODEL_PATH" "rsync" "$TRIGGER"

# Dispatch to the appropriate adapter based on model path prefix
if [[ "$MODEL_PATH" == "${HOT_HF_PATH}/models--"* ]]; then
  hf_recall_model "$MODEL_PATH" "$(dirname "$MODEL_PATH")"
elif [[ "$MODEL_PATH" == "${HOT_OLLAMA_PATH}"* ]]; then
  # Extract model name from path — Ollama models tracked by manifest name not path
  model_name=$(basename "$MODEL_PATH")
  ollama_recall_model "$model_name" "$HOT_OLLAMA_PATH"
else
  ms_die "Unknown model type: $MODEL_PATH"
fi

# Update state to cleanup phase
_write_op_state "recall" "$MODEL_PATH" "cleanup" "$TRIGGER"

# ---------------------------------------------------------------------------
# Reset usage timestamp to now (so this recall counts as a fresh access)
# Uses same flock+jq atomic pattern as ms_track_usage in watcher.sh
# ---------------------------------------------------------------------------

if [[ ! -f "$USAGE_FILE" ]]; then
  mkdir -p "$(dirname "$USAGE_FILE")"
  echo '{}' > "$USAGE_FILE"
fi

local_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
(
  flock -x 9
  jq --arg p "$MODEL_PATH" --arg t "$local_ts" '.[$p] = $t' \
    "$USAGE_FILE" > "${USAGE_FILE}.tmp" \
  && mv "${USAGE_FILE}.tmp" "$USAGE_FILE"
) 9>"${USAGE_FILE}.lock"

# ---------------------------------------------------------------------------
# Audit logging
# ---------------------------------------------------------------------------

end_epoch=$(date +%s)
duration=$(( end_epoch - start_epoch ))

# Get model size after recall (now a real directory)
size=$(du -sb "$MODEL_PATH" 2>/dev/null | cut -f1 || echo 0)

audit_log "recall" "$MODEL_PATH" "${size:-0}" "$COLD_PATH" "$MODEL_PATH" "$duration" "$TRIGGER"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

_clear_op_state

ms_log "Recall complete: $MODEL_PATH (${duration}s)"
