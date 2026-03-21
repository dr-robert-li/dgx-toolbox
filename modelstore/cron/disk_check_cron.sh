#!/usr/bin/env bash
# modelstore/cron/disk_check_cron.sh — Disk usage threshold check
# Fires a notification when either drive exceeds 98% usage.
# Uses marker files to suppress repeat notifications until usage drops below threshold.
# Called directly by crontab entry installed by modelstore init.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/config.sh
source "${SCRIPT_DIR}/../lib/config.sh"
# shellcheck source=../lib/notify.sh
source "${SCRIPT_DIR}/../lib/notify.sh"
# shellcheck source=../lib/audit.sh
source "${SCRIPT_DIR}/../lib/audit.sh"

# ---------------------------------------------------------------------------
# Load config — sets HOT_HF_PATH, HOT_OLLAMA_PATH, COLD_PATH
# ---------------------------------------------------------------------------

load_config

# ---------------------------------------------------------------------------
# check_disk_threshold <path>
#
# Checks disk usage percentage for the filesystem containing <path>.
# If usage >= 98% and no marker file exists: sends notification and creates marker.
# If usage < 98%: removes marker file to re-arm for next threshold crossing.
# ---------------------------------------------------------------------------
check_disk_threshold() {
  local path="$1"

  # Get usage percentage (e.g. "97" from "97%")
  local pct
  pct=$(df --output=pcent "$path" | tail -1 | tr -d ' %')

  # Compute a stable hash of the path string for the marker filename
  # Marker file path: ~/.modelstore/disk_alert_sent_<hash> — one per drive
  local drive_hash
  drive_hash=$(echo "$path" | md5sum | cut -d' ' -f1)
  local marker="${HOME}/.modelstore/disk_alert_sent_${drive_hash}"

  if [[ "$pct" -ge 98 ]]; then
    # Threshold crossed — check if we already sent a notification for this crossing
    if [[ ! -f "$marker" ]]; then
      # First time crossing threshold: gather disk details and notify
      local avail total
      avail=$(df -BG --output=avail "$path" | tail -1 | tr -d ' G')
      total=$(df -BG --output=size "$path" | tail -1 | tr -d ' G')

      # Determine human-readable drive label
      local drive_label
      local hot_drive_dir
      hot_drive_dir=$(dirname "$HOT_HF_PATH")
      if [[ "$path" == "$hot_drive_dir" || "$path" == "$HOT_HF_PATH" || "$path" == "$HOT_OLLAMA_PATH" ]]; then
        drive_label="Hot storage"
      elif [[ "$path" == "$COLD_PATH" ]]; then
        drive_label="Cold storage"
      else
        drive_label="Storage ($path)"
      fi

      notify_user "modelstore: disk warning" \
        "${drive_label} at ${pct}% (${avail}GB free / ${total}GB). Run: modelstore migrate"

      audit_log "disk_warning" "$path" 0 "$path" "" 0 "cron"

      # Create marker to suppress duplicate notifications until usage drops
      mkdir -p "${HOME}/.modelstore"
      touch "$marker"
    fi
    # Else: marker exists — notification already sent, suppress until recovery
  else
    # Usage dropped below threshold — remove suppression marker to re-arm
    rm -f "$marker"
  fi
}

# ---------------------------------------------------------------------------
# Main: check both hot drive and cold drive
# ---------------------------------------------------------------------------

# Hot drive: check parent directory of HOT_HF_PATH (the actual mount point)
check_disk_threshold "$(dirname "$HOT_HF_PATH")"

# Cold drive: check COLD_PATH directly
check_disk_threshold "$COLD_PATH"
