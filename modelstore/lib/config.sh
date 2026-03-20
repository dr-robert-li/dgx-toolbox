#!/usr/bin/env bash
# modelstore/lib/config.sh — JSON config read/write helpers via jq
# Sourced by modelstore.sh and all cmd/ scripts. No set -e (caller controls).
# No side effects on source: no echo, no mkdir, no exit outside functions.

# Single source of truth for config file location
MODELSTORE_CONFIG="${HOME}/.modelstore/config.json"

# ---------------------------------------------------------------------------
# Predicates
# ---------------------------------------------------------------------------

# Returns 0 if the config file exists, 1 otherwise
config_exists() {
  [[ -f "$MODELSTORE_CONFIG" ]]
}

# ---------------------------------------------------------------------------
# Read
# ---------------------------------------------------------------------------

# Read a single value from the config using a jq key expression.
# Usage: config_read <jq-key>
# Example: config_read .hot_hf_path
config_read() {
  local key="$1"
  jq -r "$key" "$MODELSTORE_CONFIG"
}

# Load config into environment variables. Exits with error if not initialized.
# Sets: HOT_HF_PATH, HOT_OLLAMA_PATH, COLD_PATH, RETENTION_DAYS, CRON_HOUR
load_config() {
  if ! config_exists; then
    echo "modelstore: not initialized. Run: modelstore init" >&2
    exit 1
  fi
  HOT_HF_PATH=$(config_read '.hot_hf_path')
  HOT_OLLAMA_PATH=$(config_read '.hot_ollama_path')
  COLD_PATH=$(config_read '.cold_path')
  RETENTION_DAYS=$(config_read '.retention_days')
  CRON_HOUR=$(config_read '.cron_hour')
}

# ---------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------

# Write a complete config file from positional args.
# Usage: write_config <hot_hf> <hot_ollama> <cold> <retention_days> <cron_hour> <backup_retention_days>
# Writes to MODELSTORE_CONFIG with chmod 600. Parent dir must exist.
write_config() {
  local hot_hf="$1"
  local hot_ollama="$2"
  local cold="$3"
  local retention_days="$4"
  local cron_hour="$5"
  local backup_retention_days="$6"

  jq -n \
    --arg hf "$hot_hf" \
    --arg ollama "$hot_ollama" \
    --arg cold "$cold" \
    --argjson ret "$retention_days" \
    --argjson hour "$cron_hour" \
    --argjson bak "$backup_retention_days" \
    '{
      version: 1,
      hot_hf_path: $hf,
      hot_ollama_path: $ollama,
      cold_path: $cold,
      retention_days: $ret,
      cron_hour: $hour,
      backup_retention_days: $bak,
      created_at: (now | todate),
      updated_at: (now | todate)
    }' > "$MODELSTORE_CONFIG"
  chmod 600 "$MODELSTORE_CONFIG"
}

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------

# If config exists, back it up with a timestamp suffix and clean up old backups.
# Old backups beyond backup_retention_days are removed.
# Usage: backup_config_if_exists
backup_config_if_exists() {
  if config_exists; then
    local backup
    backup="${MODELSTORE_CONFIG}.bak.$(date +%Y%m%dT%H%M%S)"
    cp "$MODELSTORE_CONFIG" "$backup"
    chmod 600 "$backup"
    echo "[modelstore] Backed up existing config to: $backup" >&2
    # Clean up old backups beyond retention period
    local retention_days
    retention_days=$(jq -r '.backup_retention_days // 30' "$MODELSTORE_CONFIG")
    find "$(dirname "$MODELSTORE_CONFIG")" \
      -name "config.json.bak.*" \
      -mtime "+${retention_days}" \
      -delete 2>/dev/null || true
  fi
}
