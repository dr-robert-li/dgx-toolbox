#!/usr/bin/env bash
# modelstore/cmd/status.sh — Status dashboard: model table + system summary
# Usage: status.sh
# Shows all tracked models by tier with sizes, plus system health dashboard.
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
# Load config
# ---------------------------------------------------------------------------

load_config
# Sets: HOT_HF_PATH, HOT_OLLAMA_PATH, COLD_PATH, RETENTION_DAYS, CRON_HOUR

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

USAGE_FILE="${HOME}/.modelstore/usage.json"
PIDFILE="${HOME}/.modelstore/watcher.pid"
AUDIT_LOG="${HOME}/.modelstore/audit.log"

# ---------------------------------------------------------------------------
# Human-readable size formatting (copied from migrate.sh)
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
# Model table
# ---------------------------------------------------------------------------

echo ""
echo "Models:"
printf "  %-40s  %-9s  %-6s  %-12s  %-20s  %s\n" "MODEL" "ECOSYSTEM" "TIER" "SIZE" "LAST USED" "DAYS LEFT"
printf "  %-40s  %-9s  %-6s  %-12s  %-20s  %s\n" "----------------------------------------" "---------" "------" "------------" "--------------------" "---------"

hot_count=0
cold_count=0
broken_count=0

# Collect HF models directly from HOT_HF_PATH (includes hot, cold symlinks, broken symlinks)
# We scan the directory rather than relying on hf_list_models (Python API) so we capture
# all tiers: HOT (real dir), COLD (symlink to valid target), BROKEN (dangling symlink).
# Use find -maxdepth 1 (not glob with /) so broken symlinks are included.
hf_rows=()
hf_sizes=()

while IFS= read -r model_path; do
  [[ -z "$model_path" ]] && continue
  local_size=0
  if [[ -d "$model_path" && ! -L "$model_path" ]]; then
    local_size=$(du -sb "$model_path" 2>/dev/null | cut -f1 || echo 0)
  elif [[ -L "$model_path" ]]; then
    resolved=$(readlink -f "$model_path" 2>/dev/null || true)
    if [[ -n "$resolved" && -d "$resolved" ]]; then
      local_size=$(du -sb "$resolved" 2>/dev/null | cut -f1 || echo 0)
    fi
  fi
  hf_rows+=("$model_path")
  hf_sizes+=("${local_size:-0}")
done < <(find "${HOT_HF_PATH}" -maxdepth 1 -name "models--*" 2>/dev/null | sort || true)

# Sort by size descending (bubble sort — small N for model counts)
row_count=${#hf_rows[@]}
for (( i = 0; i < row_count; i++ )); do
  for (( j = 0; j < row_count - i - 1; j++ )); do
    if [[ "${hf_sizes[$j]}" -lt "${hf_sizes[$(( j + 1 ))]}" ]]; then
      tmp_path="${hf_rows[$j]}"
      tmp_size="${hf_sizes[$j]}"
      hf_rows[$j]="${hf_rows[$(( j + 1 ))]}"
      hf_sizes[$j]="${hf_sizes[$(( j + 1 ))]}"
      hf_rows[$(( j + 1 ))]="$tmp_path"
      hf_sizes[$(( j + 1 ))]="$tmp_size"
    fi
  done
done

for (( idx = 0; idx < row_count; idx++ )); do
  model_path="${hf_rows[$idx]}"
  size_bytes="${hf_sizes[$idx]}"
  model_short=$(basename "$model_path")

  # Determine tier
  if [[ -L "$model_path" ]]; then
    resolved=$(readlink -f "$model_path" 2>/dev/null || true)
    if [[ -n "$resolved" && -e "$resolved" ]]; then
      tier="COLD"
      cold_count=$(( cold_count + 1 ))
    else
      tier="BROKEN"
      broken_count=$(( broken_count + 1 ))
    fi
  else
    tier="HOT"
    hot_count=$(( hot_count + 1 ))
  fi

  # Last used
  last_used="never"
  if [[ -f "$USAGE_FILE" ]]; then
    last_used=$(jq -r --arg k "$model_path" '.[$k] // "never"' "$USAGE_FILE" 2>/dev/null || echo "never")
  fi

  # Days left (only for HOT tier)
  if [[ "$tier" == "HOT" ]]; then
    if [[ "$last_used" != "never" ]]; then
      last_epoch=$(date -d "$last_used" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      days_elapsed=$(( ( now_epoch - last_epoch ) / 86400 ))
      days_left=$(( RETENTION_DAYS - days_elapsed ))
      [[ "$days_left" -lt 0 ]] && days_left=0
      days_left_str="${days_left}d"
    else
      days_left_str="0d"
    fi
  else
    days_left_str="---"
  fi

  size_str=$(_fmt_bytes "${size_bytes:-0}")

  printf "  %-40s  %-9s  %-6s  %-12s  %-20s  %s\n" \
    "${model_short:0:40}" "HF" "$tier" "$size_str" "${last_used:0:20}" "$days_left_str"
done

# Ollama models
ollama_output=""
ollama_output=$(ollama_list_models 2>/dev/null || true)

if [[ -z "$ollama_output" ]]; then
  echo "  (Ollama API unavailable)"
else
  while IFS=$'\t' read -r model_name size_bytes; do
    [[ -z "$model_name" ]] && continue
    size_str=$(_fmt_bytes "${size_bytes:-0}")

    # Ollama models without symlinks are HOT; with symlinks are COLD
    # Ollama doesn't use path-based symlinks like HF — all Ollama API models are HOT
    tier="HOT"
    hot_count=$(( hot_count + 1 ))

    last_used="never"
    if [[ -f "$USAGE_FILE" ]]; then
      last_used=$(jq -r --arg k "$model_name" '.[$k] // "never"' "$USAGE_FILE" 2>/dev/null || echo "never")
    fi

    if [[ "$last_used" != "never" ]]; then
      last_epoch=$(date -d "$last_used" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      days_elapsed=$(( ( now_epoch - last_epoch ) / 86400 ))
      days_left=$(( RETENTION_DAYS - days_elapsed ))
      [[ "$days_left" -lt 0 ]] && days_left=0
      days_left_str="${days_left}d"
    else
      days_left_str="0d"
    fi

    printf "  %-40s  %-9s  %-6s  %-12s  %-20s  %s\n" \
      "${model_name:0:40}" "Ollama" "$tier" "$size_str" "${last_used:0:20}" "$days_left_str"
  done <<< "$ollama_output"
fi

# ---------------------------------------------------------------------------
# Dashboard summary
# ---------------------------------------------------------------------------

echo ""
echo "System:"

# Drive totals
hot_df=""
cold_df=""
if hot_df=$(df -BG "$HOT_HF_PATH" 2>/dev/null | awk 'NR==2 {used=$3; size=$2; gsub(/G/,"",used); gsub(/G/,"",size); printf "%sGB/%sGB", used, size}'); then
  true
else
  hot_df="unavailable"
fi
if cold_df=$(df -BG "$COLD_PATH" 2>/dev/null | awk 'NR==2 {used=$3; size=$2; gsub(/G/,"",used); gsub(/G/,"",size); printf "%sGB/%sGB", used, size}'); then
  true
else
  cold_df="unavailable"
fi
printf "  Hot: %s used, Cold: %s used\n" "$hot_df" "$cold_df"

# Model counts
printf "  %d model%s hot, %d cold, %d broken\n" \
  "$hot_count" "$([ "$hot_count" -ne 1 ] && echo 's' || true)" \
  "$cold_count" "$broken_count"

# Watcher status
watcher_status="stopped"
if [[ -f "$PIDFILE" ]]; then
  watcher_pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if [[ -n "$watcher_pid" ]] && kill -0 "$watcher_pid" 2>/dev/null; then
    watcher_status="running (PID ${watcher_pid})"
  fi
fi
printf "  Watcher: %s\n" "$watcher_status"

# Cron status
cron_status="not installed"
if crontab -l 2>/dev/null | grep -q "modelstore"; then
  cron_status="installed"
  cron_line=$(crontab -l 2>/dev/null | grep "modelstore" | head -1 || true)
  # Extract hour from cron expression (field 2, 0-indexed field 1)
  cron_hour_val=$(echo "$cron_line" | awk '{print $2}' 2>/dev/null || true)
  [[ -n "$cron_hour_val" ]] && cron_status="installed (hour=${cron_hour_val})"
fi
printf "  Cron: %s\n" "$cron_status"

# Last migration
last_migration="never"
if [[ -f "$AUDIT_LOG" ]]; then
  last_migration=$(grep '"event":"migrate"' "$AUDIT_LOG" 2>/dev/null | tail -1 | jq -r '.timestamp // empty' 2>/dev/null || true)
  [[ -z "$last_migration" ]] && last_migration="never"
fi
printf "  Last migration: %s\n" "$last_migration"

echo ""
