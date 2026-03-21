#!/usr/bin/env bash
# modelstore/cmd/revert.sh — Full revert: recall all cold models, remove cron/watcher/cold dirs
# Usage: revert.sh [--force]
# --force: skip confirmation prompt (required when stdin is not a TTY)
# Interrupt-safe: tracks completed_models in op_state.json for resume after interruption.
# Does NOT remove ~/.modelstore/config.json (preserves user config).
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

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------

load_config
# Sets: HOT_HF_PATH, HOT_OLLAMA_PATH, COLD_PATH, RETENTION_DAYS, CRON_HOUR

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

OP_STATE_FILE="${HOME}/.modelstore/op_state.json"
USAGE_FILE="${HOME}/.modelstore/usage.json"
PIDFILE="${HOME}/.modelstore/watcher.pid"
# NOTE: config.json is preserved — revert does NOT remove ~/.modelstore/config.json

# ---------------------------------------------------------------------------
# State helpers (interrupt-safe multi-model tracking)
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

# _init_revert_state <total>: initializes op_state.json for a new revert run
_init_revert_state() {
  local total="$1"
  jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson total "$total" \
    '{op:"revert", phase:"recall_hf", started_at:$ts, trigger:"manual", completed_models:[], total_models:$total}' \
    > "${OP_STATE_FILE}.tmp"
  mv "${OP_STATE_FILE}.tmp" "$OP_STATE_FILE"
}

# _append_completed <model_path>: atomically adds model to completed_models array
_append_completed() {
  local model="$1"
  jq --arg m "$model" '.completed_models += [$m]' "$OP_STATE_FILE" \
    > "${OP_STATE_FILE}.tmp"
  mv "${OP_STATE_FILE}.tmp" "$OP_STATE_FILE"
}

# _is_completed <model_path>: returns 0 if model is in completed_models
_is_completed() {
  local model="$1"
  if [[ ! -f "$OP_STATE_FILE" ]]; then
    return 1
  fi
  jq -e --arg m "$model" '.completed_models | index($m) != null' "$OP_STATE_FILE" &>/dev/null
}

# ---------------------------------------------------------------------------
# Startup check 1: cold drive must be mounted
# ---------------------------------------------------------------------------

check_cold_mounted "$COLD_PATH"

# ---------------------------------------------------------------------------
# Startup check 2: handle existing op_state.json
# ---------------------------------------------------------------------------

RESUMING=false
COMPLETED_MODELS=()

if [[ -f "$OP_STATE_FILE" ]]; then
  existing_op=$(jq -r '.op // empty' "$OP_STATE_FILE" 2>/dev/null || true)
  op_started_at=$(jq -r '.started_at // empty' "$OP_STATE_FILE" 2>/dev/null || true)

  if [[ -n "$op_started_at" ]]; then
    op_epoch=$(date -d "$op_started_at" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    age_sec=$(( now_epoch - op_epoch ))

    if [[ "$existing_op" != "revert" ]]; then
      # Non-revert operation in progress
      if [[ "$age_sec" -lt 14400 ]]; then
        # Fresh (< 4 hours) — abort to avoid interference
        ms_die "Another operation in progress (${existing_op}). Wait or check state: ${OP_STATE_FILE}"
      else
        # Stale (>= 4 hours) — clear and proceed
        ms_log "WARNING: Clearing stale operation state (op=${existing_op}, started at ${op_started_at})"
        _clear_op_state
      fi
    else
      # .op == "revert" — resume interrupted revert
      ms_log "Resuming interrupted revert (started at ${op_started_at})"
      RESUMING=true
      # Load completed models list
      while IFS= read -r completed_model; do
        [[ -n "$completed_model" ]] && COMPLETED_MODELS+=("$completed_model")
      done < <(jq -r '.completed_models[]?' "$OP_STATE_FILE" 2>/dev/null || true)
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Collect migrated HF models (symlinks in HOT_HF_PATH)
# ---------------------------------------------------------------------------

hf_models=()
while IFS= read -r model_path; do
  [[ -z "$model_path" ]] && continue
  [[ -L "$model_path" ]] || continue
  hf_models+=("$model_path")
done < <(find "${HOT_HF_PATH}" -maxdepth 1 -name "models--*" -type l 2>/dev/null | sort || true)

# Collect migrated Ollama models (symlinks in HOT_OLLAMA_PATH blobs)
ollama_models=()
ollama_manifests_dir="${HOT_OLLAMA_PATH}/models/manifests/registry.ollama.ai/library"
if [[ -d "$ollama_manifests_dir" ]]; then
  while IFS= read -r model_dir; do
    model_base=$(basename "$model_dir")
    for tag_file in "${model_dir}"/*/; do
      tag_path="${tag_file%/}"
      [[ -f "$tag_path" ]] || continue
      tag=$(basename "$tag_path")
      ollama_models+=("${model_base}:${tag}")
    done
  done < <(find "$ollama_manifests_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort || true)
fi

total_count=$(( ${#hf_models[@]} + ${#ollama_models[@]} ))

# ---------------------------------------------------------------------------
# Preview + confirmation (unless --force or no TTY)
# ---------------------------------------------------------------------------

if [[ "$FORCE" != "true" ]]; then
  if [[ ! -t 0 ]]; then
    ms_die "No TTY for confirmation. Use --force for headless execution."
  fi
  # Interactive preview
  echo ""
  echo "Revert preview: ${total_count} model(s) will be recalled from cold storage"
  echo ""
  printf "  %-45s  %-10s\n" "MODEL" "ECOSYSTEM"
  for model_path in "${hf_models[@]}"; do
    printf "  %-45s  %-10s\n" "$(basename "$model_path")" "HF"
  done
  for model_name in "${ollama_models[@]}"; do
    printf "  %-45s  %-10s\n" "$model_name" "Ollama"
  done
  echo ""
  echo "Additional actions:"
  echo "  - Remove cron entries for modelstore"
  echo "  - Stop watcher daemon"
  echo "  - Remove ${COLD_PATH}/hf and ${COLD_PATH}/ollama directories"
  echo "  - Keep ${HOME}/.modelstore/config.json"
  echo ""
  echo -n "Proceed with full revert? [y/N] "
  read -r confirm || confirm=""
  if [[ "${confirm,,}" != "y" ]]; then
    ms_log "Revert cancelled"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Initialize revert state (if not resuming)
# ---------------------------------------------------------------------------

if [[ "$RESUMING" != "true" ]]; then
  _init_revert_state "$total_count"
fi

# ---------------------------------------------------------------------------
# Recall loop: HF models
# ---------------------------------------------------------------------------

ms_log "Starting revert: ${#hf_models[@]} HF model(s), ${#ollama_models[@]} Ollama model(s)"

for model_path in "${hf_models[@]}"; do
  [[ -z "$model_path" ]] && continue

  # Skip if already completed (interrupt resume)
  if _is_completed "$model_path"; then
    ms_log "Skipping already reverted: $model_path"
    continue
  fi

  start_epoch=$(date +%s)
  jq --arg ph "recall_hf" --arg m "$model_path" \
    '.phase = $ph | .model = $m' "$OP_STATE_FILE" > "${OP_STATE_FILE}.tmp" \
    && mv "${OP_STATE_FILE}.tmp" "$OP_STATE_FILE"

  if hf_recall_model "$model_path" "$(dirname "$model_path")" 2>&1; then
    end_epoch=$(date +%s)
    duration=$(( end_epoch - start_epoch ))
    size=$(du -sb "$model_path" 2>/dev/null | cut -f1 || echo 0)
    audit_log "revert" "$model_path" "${size:-0}" "${COLD_PATH}/hf" "$model_path" "$duration" "manual"
    _append_completed "$model_path"
    ms_log "Recalled: $model_path"
  else
    ms_log "WARNING: Failed to recall: $model_path (continuing)"
  fi
done

# ---------------------------------------------------------------------------
# Recall loop: Ollama models
# ---------------------------------------------------------------------------

for model_name in "${ollama_models[@]}"; do
  [[ -z "$model_name" ]] && continue

  if _is_completed "$model_name"; then
    ms_log "Skipping already reverted: $model_name"
    continue
  fi

  jq --arg ph "recall_ollama" --arg m "$model_name" \
    '.phase = $ph | .model = $m' "$OP_STATE_FILE" > "${OP_STATE_FILE}.tmp" \
    && mv "${OP_STATE_FILE}.tmp" "$OP_STATE_FILE"

  if ollama_recall_model "$model_name" "$HOT_OLLAMA_PATH" 2>&1; then
    audit_log "revert" "$model_name" "0" "${COLD_PATH}/ollama" "$HOT_OLLAMA_PATH" "0" "manual"
    _append_completed "$model_name"
    ms_log "Recalled Ollama: $model_name"
  else
    ms_log "WARNING: Failed to recall Ollama model: $model_name (continuing)"
  fi
done

# ---------------------------------------------------------------------------
# Cleanup phase: cron entries
# ---------------------------------------------------------------------------

jq '.phase = "cleanup_cron"' "$OP_STATE_FILE" > "${OP_STATE_FILE}.tmp" \
  && mv "${OP_STATE_FILE}.tmp" "$OP_STATE_FILE"

ms_log "Cleanup: removing cron entries"
if crontab -l 2>/dev/null | grep -q "modelstore"; then
  crontab -l 2>/dev/null | grep -v "modelstore" | crontab -
  ms_log "Cron entries removed"
else
  ms_log "No cron entries to remove"
fi

# ---------------------------------------------------------------------------
# Cleanup phase: watcher daemon
# ---------------------------------------------------------------------------

jq '.phase = "cleanup_watcher"' "$OP_STATE_FILE" > "${OP_STATE_FILE}.tmp" \
  && mv "${OP_STATE_FILE}.tmp" "$OP_STATE_FILE"

ms_log "Cleanup: stopping watcher"
if [[ -f "$PIDFILE" ]]; then
  watcher_pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if [[ -n "$watcher_pid" ]]; then
    kill "$watcher_pid" 2>/dev/null || true
    ms_log "Stopped watcher (PID ${watcher_pid})"
  fi
  rm -f "$PIDFILE"
fi

# ---------------------------------------------------------------------------
# Cleanup phase: cold storage directories
# ---------------------------------------------------------------------------

jq '.phase = "cleanup_cold_dir"' "$OP_STATE_FILE" > "${OP_STATE_FILE}.tmp" \
  && mv "${OP_STATE_FILE}.tmp" "$OP_STATE_FILE"

ms_log "Cleanup: removing cold storage model directories"
rm -rf "${COLD_PATH}/hf" "${COLD_PATH}/ollama" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Done: clear op state and report
# ---------------------------------------------------------------------------

_clear_op_state

ms_log "Revert complete: ${total_count} model(s) recalled, cron/watcher/cold-dirs cleaned up"
ms_log "Note: ${HOME}/.modelstore/config.json preserved (run 'modelstore init' to reconfigure)"
