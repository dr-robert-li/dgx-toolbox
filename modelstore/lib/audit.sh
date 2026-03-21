#!/usr/bin/env bash
# modelstore/lib/audit.sh — Audit logging for modelstore operations
# Provides audit_log() for writing JSON-line entries to ~/.modelstore/audit.log.
# Annual log rotation: when the calendar year changes, the old log is renamed.
# Sourced by migrate.sh, recall.sh, disk_check_cron.sh — no set -e (caller controls).

_MS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${_MS_LIB}/common.sh"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

AUDIT_LOG="${HOME}/.modelstore/audit.log"
AUDIT_LOCK="${HOME}/.modelstore/audit.lock"

# ---------------------------------------------------------------------------
# _audit_rotate_if_needed
# Rotates the audit log if the current year differs from the log's year.
# Renames: ~/.modelstore/audit.log -> ~/.modelstore/audit.<year>.log
# ---------------------------------------------------------------------------
_audit_rotate_if_needed() {
  [[ -f "$AUDIT_LOG" ]] || return 0

  local current_year log_year
  current_year=$(date +%Y)
  # Read first line, extract timestamp, take first 4 chars as year
  log_year=$(head -1 "$AUDIT_LOG" 2>/dev/null | jq -r '.timestamp // empty' 2>/dev/null | cut -c1-4)

  # If we could not determine the log year, skip rotation
  [[ -z "$log_year" ]] && return 0

  # Same year — no rotation needed
  [[ "$log_year" == "$current_year" ]] && return 0

  # Year boundary crossed — rotate
  mv "$AUDIT_LOG" "${AUDIT_LOG%.log}.${log_year}.log"
}

# ---------------------------------------------------------------------------
# audit_log <event> <model> <size_bytes> <source> <dest> <duration_sec> <trigger> [error]
#
# Writes a JSON-line entry to ~/.modelstore/audit.log.
# Parameters:
#   event        — migrate | recall | fail | disk_warning
#   model        — absolute model path or model name
#   size_bytes   — integer bytes (use 0 if unknown)
#   source       — source path
#   dest         — destination path
#   duration_sec — integer seconds elapsed
#   trigger      — cron | manual | auto
#   error        — error message string, or "null" (default) for no error
# ---------------------------------------------------------------------------
audit_log() {
  local event="$1"
  local model="$2"
  local size_bytes="${3:-0}"
  local source="${4:-}"
  local dest="${5:-}"
  local duration_sec="${6:-0}"
  local trigger="${7:-manual}"
  local error="${8:-null}"

  # Ensure modelstore state dir exists
  mkdir -p "$(dirname "$AUDIT_LOG")"

  # Annual rotation check
  _audit_rotate_if_needed

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local entry
  entry=$(jq -cn \
    --arg ts "$timestamp" \
    --arg ev "$event" \
    --arg mo "$model" \
    --argjson sz "$size_bytes" \
    --arg src "$source" \
    --arg dst "$dest" \
    --argjson dur "$duration_sec" \
    --arg tr "$trigger" \
    --arg err "$error" \
    '{
      timestamp: $ts,
      event: $ev,
      model: $mo,
      size_bytes: $sz,
      source: $src,
      dest: $dst,
      duration_sec: $dur,
      trigger: $tr,
      error: (if $err == "null" then null else $err end)
    }')

  # Atomic append under exclusive flock (same pattern as ms_track_usage in watcher.sh)
  (
    flock -x 9
    echo "$entry" >> "$AUDIT_LOG"
  ) 9>"$AUDIT_LOCK"
}
