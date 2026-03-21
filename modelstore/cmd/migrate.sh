#!/usr/bin/env bash
# modelstore/cmd/migrate.sh — Hot-to-cold migration for stale models
# Usage: migrate.sh [--dry-run]
# Env:   TRIGGER_SOURCE=cron  (set by migrate_cron.sh for audit trail)
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

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

TRIGGER="manual"
[[ "${TRIGGER_SOURCE:-}" == "cron" ]] && TRIGGER="cron"

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------

load_config
# Sets: HOT_HF_PATH, HOT_OLLAMA_PATH, COLD_PATH, RETENTION_DAYS, CRON_HOUR

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

USAGE_FILE="${HOME}/.modelstore/usage.json"
OP_STATE_FILE="${HOME}/.modelstore/op_state.json"

# ---------------------------------------------------------------------------
# State file helpers (SAFE-05 interrupt safety)
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
# Handle stale state file on startup
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
# Stale model detection
# ---------------------------------------------------------------------------

# find_stale_hf_models: prints stale HF model paths to stdout
find_stale_hf_models() {
  local cutoff_epoch
  cutoff_epoch=$(date -d "${RETENTION_DAYS} days ago" +%s)

  # Models in usage.json that are past retention period
  if [[ -f "$USAGE_FILE" ]]; then
    jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$USAGE_FILE" 2>/dev/null \
    | while IFS=$'\t' read -r model_path last_used; do
        [[ "$model_path" != "${HOT_HF_PATH}/models--"* ]] && continue
        [[ -L "$model_path" ]] && continue  # already migrated — skip
        local last_epoch
        last_epoch=$(date -d "$last_used" +%s 2>/dev/null || echo 0)
        [[ "$last_epoch" -lt "$cutoff_epoch" ]] && echo "$model_path"
      done
  fi

  # Models not in usage.json at all (never tracked = treat as stale)
  for model_dir in "${HOT_HF_PATH}"/models--*/; do
    [[ -d "$model_dir" ]] || continue
    local key="${model_dir%/}"
    [[ -L "$key" ]] && continue  # already migrated — skip
    if ! jq -e --arg k "$key" 'has($k)' "$USAGE_FILE" &>/dev/null 2>&1; then
      echo "$key"
    fi
  done
}

# find_stale_ollama_models: prints stale Ollama model names to stdout
find_stale_ollama_models() {
  local cutoff_epoch
  cutoff_epoch=$(date -d "${RETENTION_DAYS} days ago" +%s)

  # Models in usage.json that are past retention period
  if [[ -f "$USAGE_FILE" ]]; then
    jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$USAGE_FILE" 2>/dev/null \
    | while IFS=$'\t' read -r model_path last_used; do
        [[ "$model_path" != "${HOT_OLLAMA_PATH}"* ]] && continue
        # Extract model name from path heuristic — use path as key
        local last_epoch
        last_epoch=$(date -d "$last_used" +%s 2>/dev/null || echo 0)
        [[ "$last_epoch" -lt "$cutoff_epoch" ]] && echo "$model_path"
      done
  fi

  # Walk manifest directories for untracked Ollama models
  local manifests_dir="${HOT_OLLAMA_PATH}/models/manifests/registry.ollama.ai/library"
  if [[ -d "$manifests_dir" ]]; then
    for model_dir in "${manifests_dir}"/*/; do
      [[ -d "$model_dir" ]] || continue
      local model_base
      model_base=$(basename "$model_dir")
      for tag_file in "${model_dir}"*/; do
        local tag_path="${tag_file%/}"
        [[ -f "$tag_path" ]] || continue
        local tag
        tag=$(basename "$tag_path")
        local model_name="${model_base}:${tag}"
        local usage_key="${HOT_OLLAMA_PATH}/models/manifests/registry.ollama.ai/library/${model_base}/${tag}"
        if ! jq -e --arg k "$usage_key" 'has($k)' "$USAGE_FILE" &>/dev/null 2>&1; then
          echo "$model_name"
        fi
      done
    done
  fi
}

# ---------------------------------------------------------------------------
# Human-readable size formatting
# ---------------------------------------------------------------------------

_fmt_bytes() {
  local bytes="$1"
  if [[ "$bytes" -ge 1073741824 ]]; then
    printf "%.1f GB" "$(echo "scale=1; $bytes / 1073741824" | bc 2>/dev/null || echo 0)"
  elif [[ "$bytes" -ge 1048576 ]]; then
    printf "%.1f MB" "$(echo "scale=1; $bytes / 1048576" | bc 2>/dev/null || echo 0)"
  else
    printf "%d B" "$bytes"
  fi
}

# ---------------------------------------------------------------------------
# Dry-run mode: print tables, exit without modifying data
# ---------------------------------------------------------------------------

if [[ "$DRY_RUN" == "true" ]]; then
  ms_log "Dry-run mode: no data will be modified"

  # Collect stale HF models
  mapfile -t stale_hf < <(find_stale_hf_models 2>/dev/null || true)

  # Collect stale Ollama models
  mapfile -t stale_ollama < <(find_stale_ollama_models 2>/dev/null || true)

  total_count=$(( ${#stale_hf[@]} + ${#stale_ollama[@]} ))
  total_bytes=0

  # Print "Would migrate" table
  echo ""
  echo "Would migrate (${total_count} models):"
  printf "  %-45s  %-10s  %-20s  %-10s  %s\n" "MODEL" "SIZE" "LAST USED" "DAYS AGO" "ACTION"

  # HF models
  for model_path in "${stale_hf[@]}"; do
    [[ -z "$model_path" ]] && continue
    local_size=$(hf_get_model_size "$model_path" 2>/dev/null || echo 0)
    total_bytes=$(( total_bytes + local_size ))
    last_used=$(jq -r --arg k "$model_path" '.[$k] // "never"' "$USAGE_FILE" 2>/dev/null || echo "never")
    if [[ "$last_used" != "never" ]]; then
      last_epoch=$(date -d "$last_used" +%s 2>/dev/null || echo 0)
      days_ago=$(( ( $(date +%s) - last_epoch ) / 86400 ))
    else
      days_ago="unknown"
    fi
    model_short=$(basename "$model_path")
    printf "  %-45s  %-10s  %-20s  %-10s  %s\n" \
      "${model_short:0:45}" "$(_fmt_bytes "$local_size")" "$last_used" "${days_ago}d" "hot -> cold (hf)"
  done

  # Ollama models
  for model_name in "${stale_ollama[@]}"; do
    [[ -z "$model_name" ]] && continue
    ollama_size=$(ollama_get_model_size "$model_name" 2>/dev/null || echo 0)
    [[ -z "$ollama_size" ]] && ollama_size=0
    total_bytes=$(( total_bytes + ollama_size ))
    printf "  %-45s  %-10s  %-20s  %-10s  %s\n" \
      "${model_name:0:45}" "$(_fmt_bytes "$ollama_size")" "unknown" "unknown" "hot -> cold (ollama)"
  done

  echo ""
  echo "  Total: $(_fmt_bytes "$total_bytes") in ${total_count} models"

  # Print "Keeping hot" table — HF models NOT in stale list
  echo ""
  echo "Keeping hot:"
  printf "  %-45s  %-10s  %-20s  %s\n" "MODEL" "SIZE" "LAST USED" "REASON"

  for model_dir in "${HOT_HF_PATH}"/models--*/; do
    [[ -d "$model_dir" || -L "${model_dir%/}" ]] || continue
    local_path="${model_dir%/}"
    # Check if it's a symlink (already on cold)
    if [[ -L "$local_path" ]]; then
      model_short=$(basename "$local_path")
      printf "  %-45s  %-10s  %-20s  %s\n" \
        "${model_short:0:45}" "---" "---" "already on cold"
      continue
    fi
    # Check if it's in the stale list
    is_stale=false
    for stale in "${stale_hf[@]}"; do
      [[ "$stale" == "$local_path" ]] && { is_stale=true; break; }
    done
    [[ "$is_stale" == "true" ]] && continue  # will migrate, not keeping
    last_used=$(jq -r --arg k "$local_path" '.[$k] // "never"' "$USAGE_FILE" 2>/dev/null || echo "never")
    model_short=$(basename "$local_path")
    printf "  %-45s  %-10s  %-20s  %s\n" \
      "${model_short:0:45}" "---" "$last_used" "used within ${RETENTION_DAYS} days"
  done

  # Cold store available space
  echo ""
  echo "Cold store available space:"
  df -BG --output=avail,size "$COLD_PATH" 2>/dev/null || echo "  (cold store not mounted)"

  exit 0
fi

# ---------------------------------------------------------------------------
# Real migration mode
# ---------------------------------------------------------------------------

# Ensure cold drive is mounted
check_cold_mounted "$COLD_PATH"

ms_log "Starting migration (trigger=${TRIGGER})"

migrated_count=0
failed_count=0

# Migrate stale HF models
while IFS= read -r model_path; do
  [[ -z "$model_path" ]] && continue

  model_size=$(hf_get_model_size "$model_path" 2>/dev/null || echo 0)
  start_epoch=$(date +%s)

  _write_op_state "migrate" "$model_path" "rsync" "$TRIGGER"

  if hf_migrate_model "$model_path" "$COLD_PATH" 2>&1; then
    _write_op_state "migrate" "$model_path" "cleanup" "$TRIGGER"
    end_epoch=$(date +%s)
    duration=$(( end_epoch - start_epoch ))
    audit_log "migrate" "$model_path" "$model_size" \
      "$model_path" "${COLD_PATH}/hf/$(basename "$model_path")" \
      "$duration" "$TRIGGER"
    migrated_count=$(( migrated_count + 1 ))
  else
    end_epoch=$(date +%s)
    duration=$(( end_epoch - start_epoch ))
    audit_log "fail" "$model_path" "$model_size" \
      "$model_path" "" "$duration" "$TRIGGER" "migration failed"
    failed_count=$(( failed_count + 1 ))
  fi

  _clear_op_state
done < <(find_stale_hf_models 2>/dev/null || true)

# Migrate stale Ollama models
while IFS= read -r model_name; do
  [[ -z "$model_name" ]] && continue

  ollama_size=$(ollama_get_model_size "$model_name" 2>/dev/null || echo 0)
  [[ -z "$ollama_size" ]] && ollama_size=0
  start_epoch=$(date +%s)

  _write_op_state "migrate" "$model_name" "rsync" "$TRIGGER"

  if ollama_migrate_model "$model_name" "$COLD_PATH" 2>&1; then
    _write_op_state "migrate" "$model_name" "cleanup" "$TRIGGER"
    end_epoch=$(date +%s)
    duration=$(( end_epoch - start_epoch ))
    audit_log "migrate" "$model_name" "$ollama_size" \
      "${HOT_OLLAMA_PATH}" "${COLD_PATH}/ollama" \
      "$duration" "$TRIGGER"
    migrated_count=$(( migrated_count + 1 ))
  else
    end_epoch=$(date +%s)
    duration=$(( end_epoch - start_epoch ))
    audit_log "fail" "$model_name" "$ollama_size" \
      "${HOT_OLLAMA_PATH}" "" "$duration" "$TRIGGER" "migration failed"
    failed_count=$(( failed_count + 1 ))
  fi

  _clear_op_state
done < <(find_stale_ollama_models 2>/dev/null || true)

ms_log "Migration complete: ${migrated_count} models moved, ${failed_count} failed"
