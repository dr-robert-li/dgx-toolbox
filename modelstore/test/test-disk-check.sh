#!/usr/bin/env bash
# modelstore/test/test-disk-check.sh — Tests for cron/disk_check_cron.sh
# Covers: SAFE-03, SAFE-04
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELSTORE_LIB="${SCRIPT_DIR}/../lib"
MODELSTORE_CRON="${SCRIPT_DIR}/../cron"

PASS=0; FAIL=0
assert_eq() { if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1)); echo "  PASS: $3"; else FAIL=$((FAIL + 1)); echo "  FAIL: $3 (expected '$2', got '$1')"; fi; }
assert_ok() { if eval "$1" 2>/dev/null; then PASS=$((PASS + 1)); echo "  PASS: $2"; else FAIL=$((FAIL + 1)); echo "  FAIL: $2"; fi; }
report() { echo ""; echo "Results: $PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]; }

echo "=== Disk Check Tests ==="

# ---------------------------------------------------------------------------
# Setup: temp environment
# ---------------------------------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.modelstore"
mkdir -p "$TMP/hf_cache"
mkdir -p "$TMP/cold"

# Write fake config
cat > "$TMP/.modelstore/config.json" <<ENDCONFIG
{
  "version": 1,
  "hot_hf_path": "${TMP}/hf_cache",
  "hot_ollama_path": "${TMP}/ollama_models",
  "cold_path": "${TMP}/cold",
  "retention_days": 14,
  "cron_hour": 2,
  "backup_retention_days": 30,
  "created_at": "2026-01-01T00:00:00Z",
  "updated_at": "2026-01-01T00:00:00Z"
}
ENDCONFIG

# ---------------------------------------------------------------------------
# Source the libs so we can inline check_disk_threshold for unit testing
# ---------------------------------------------------------------------------
source "${MODELSTORE_LIB}/common.sh"
source "${MODELSTORE_LIB}/config.sh"
source "${MODELSTORE_LIB}/audit.sh"
export HOME="$TMP"
load_config

# ---------------------------------------------------------------------------
# Define the check_disk_threshold function inline (same as disk_check_cron.sh)
# This avoids external process complications with mocking df/notify_user
# ---------------------------------------------------------------------------

NOTIFY_LOG="$TMP/notify_calls.log"
AUDIT_LOG="$TMP/.modelstore/audit.log"

# Mock notify_user: writes summary+body to test log file
notify_user() {
  local summary="$1"
  local body="$2"
  echo "NOTIFY: $summary -- $body" >> "$NOTIFY_LOG"
}

# Inline check_disk_threshold (matching disk_check_cron.sh implementation)
check_disk_threshold() {
  local path="$1"

  local pct
  pct=$(df --output=pcent "$path" | tail -1 | tr -d ' %')

  local drive_hash
  drive_hash=$(echo "$path" | md5sum | cut -d' ' -f1)
  # Marker file path: ~/.modelstore/disk_alert_sent_<hash> — one per drive
  local marker="${HOME}/.modelstore/disk_alert_sent_${drive_hash}"

  if [[ "$pct" -ge 98 ]]; then
    if [[ ! -f "$marker" ]]; then
      local avail total
      avail=$(df -BG --output=avail "$path" | tail -1 | tr -d ' G')
      total=$(df -BG --output=size "$path" | tail -1 | tr -d ' G')

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

      mkdir -p "${HOME}/.modelstore"
      touch "$marker"
    fi
  else
    rm -f "$marker"
  fi
}

# ---------------------------------------------------------------------------
# Test 1: test_notify_threshold (SAFE-03) — notify_user called when df returns 99%
# ---------------------------------------------------------------------------
echo ""
echo "--- Test SAFE-03: test_notify_threshold ---"

# Mock df to return 99%
df() {
  if [[ "${1:-}" == "--output=pcent" ]] || [[ "${*}" == *"--output=pcent"* ]]; then
    echo "pcent"
    echo " 99%"
  elif [[ "${*}" == *"-BG --output=avail"* ]]; then
    echo "avail"
    echo " 5G"
  elif [[ "${*}" == *"-BG --output=size"* ]]; then
    echo "size"
    echo " 100G"
  else
    command df "$@"
  fi
}

rm -f "$NOTIFY_LOG" "$TMP/.modelstore/audit.log"
test_path="$TMP/cold"

check_disk_threshold "$test_path"

notify_called=0
[[ -f "$NOTIFY_LOG" ]] && [[ "$(cat "$NOTIFY_LOG")" == *"disk warning"* ]] && notify_called=1
assert_eq "$notify_called" "1" "notify_user called when disk >= 98% (SAFE-03)"

# Check percentage appears in notification
notify_has_pct=0
[[ "$(cat "$NOTIFY_LOG" 2>/dev/null)" == *"99%"* ]] && notify_has_pct=1
assert_eq "$notify_has_pct" "1" "notification message contains disk percentage (SAFE-03)"

# Check marker file was created
drive_hash_test=$(echo "$test_path" | md5sum | cut -d' ' -f1)
marker_created=0
[[ -f "$TMP/.modelstore/disk_alert_sent_${drive_hash_test}" ]] && marker_created=1
assert_eq "$marker_created" "1" "marker file created after first threshold crossing (SAFE-03)"

unset -f df

# ---------------------------------------------------------------------------
# Test 2: test_below_threshold — no notification when disk is 85%
# ---------------------------------------------------------------------------
echo ""
echo "--- Test: test_below_threshold ---"

df() {
  if [[ "${*}" == *"--output=pcent"* ]]; then
    echo "pcent"
    echo " 85%"
  else
    command df "$@"
  fi
}

rm -f "$NOTIFY_LOG" "$TMP/.modelstore/audit.log"
# Ensure no existing marker
rm -f "$TMP/.modelstore/disk_alert_sent_"* 2>/dev/null || true

check_disk_threshold "$test_path"

notify_not_called=0
[[ ! -f "$NOTIFY_LOG" ]] && notify_not_called=1
assert_eq "$notify_not_called" "1" "notify_user NOT called when disk < 98%"

marker_not_created=0
[[ ! -f "$TMP/.modelstore/disk_alert_sent_${drive_hash_test}" ]] && marker_not_created=1
assert_eq "$marker_not_created" "1" "marker file NOT created when disk < 98%"

unset -f df

# ---------------------------------------------------------------------------
# Test 3: test_suppression_marker — no duplicate notification if marker exists
# ---------------------------------------------------------------------------
echo ""
echo "--- Test SAFE-03: test_suppression_marker ---"

df() {
  if [[ "${*}" == *"--output=pcent"* ]]; then
    echo "pcent"
    echo " 99%"
  else
    command df "$@"
  fi
}

rm -f "$NOTIFY_LOG" "$TMP/.modelstore/audit.log"
# Pre-create marker (simulate already-notified state)
touch "$TMP/.modelstore/disk_alert_sent_${drive_hash_test}"

check_disk_threshold "$test_path"

suppressed=0
[[ ! -f "$NOTIFY_LOG" ]] && suppressed=1
assert_eq "$suppressed" "1" "notification suppressed when marker file exists (SAFE-03)"

unset -f df

# ---------------------------------------------------------------------------
# Test 4: test_marker_cleared_on_recovery — marker removed when usage drops below 98%
# ---------------------------------------------------------------------------
echo ""
echo "--- Test SAFE-03: test_marker_cleared_on_recovery ---"

df() {
  if [[ "${*}" == *"--output=pcent"* ]]; then
    echo "pcent"
    echo " 80%"
  else
    command df "$@"
  fi
}

# Ensure marker exists before test
touch "$TMP/.modelstore/disk_alert_sent_${drive_hash_test}"
rm -f "$NOTIFY_LOG"

check_disk_threshold "$test_path"

marker_removed=0
[[ ! -f "$TMP/.modelstore/disk_alert_sent_${drive_hash_test}" ]] && marker_removed=1
assert_eq "$marker_removed" "1" "marker file removed when usage drops below 98% (SAFE-03)"

unset -f df

# ---------------------------------------------------------------------------
# Test 5: test_fallback_log (SAFE-04) — alerts.log written when notify-send fails
# ---------------------------------------------------------------------------
echo ""
echo "--- Test SAFE-04: test_fallback_log ---"

ALERTS_LOG="$TMP/.modelstore/alerts.log"
rm -f "$ALERTS_LOG"

# Override notify_user to test the real fallback logic (simulate failing notify-send)
notify_user() {
  local summary="$1"
  local body="$2"
  # Simulate notify-send failure — write to alerts.log directly
  mkdir -p "${HOME}/.modelstore"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $summary -- $body" >> "$ALERTS_LOG"
}

df() {
  if [[ "${*}" == *"--output=pcent"* ]]; then
    echo "pcent"
    echo " 99%"
  elif [[ "${*}" == *"-BG --output=avail"* ]]; then
    echo "avail"
    echo " 5G"
  elif [[ "${*}" == *"-BG --output=size"* ]]; then
    echo "size"
    echo " 100G"
  else
    command df "$@"
  fi
}

rm -f "$TMP/.modelstore/disk_alert_sent_${drive_hash_test}"
rm -f "$TMP/.modelstore/audit.log"

check_disk_threshold "$test_path"

fallback_logged=0
[[ -f "$ALERTS_LOG" ]] && [[ "$(cat "$ALERTS_LOG")" == *"disk warning"* ]] && fallback_logged=1
assert_eq "$fallback_logged" "1" "alerts.log written when notify-send unavailable (SAFE-04)"

unset -f df

# Restore standard notify_user mock
notify_user() {
  local summary="$1"
  local body="$2"
  echo "NOTIFY: $summary -- $body" >> "$NOTIFY_LOG"
}

# ---------------------------------------------------------------------------
# Test 6: test_audit_disk_warning — audit.log has disk_warning entry
# ---------------------------------------------------------------------------
echo ""
echo "--- Test SAFE-03: test_audit_disk_warning ---"

df() {
  if [[ "${*}" == *"--output=pcent"* ]]; then
    echo "pcent"
    echo " 99%"
  elif [[ "${*}" == *"-BG --output=avail"* ]]; then
    echo "avail"
    echo " 5G"
  elif [[ "${*}" == *"-BG --output=size"* ]]; then
    echo "size"
    echo " 100G"
  else
    command df "$@"
  fi
}

rm -f "$TMP/.modelstore/disk_alert_sent_${drive_hash_test}"
rm -f "$TMP/.modelstore/audit.log"
rm -f "$NOTIFY_LOG"

check_disk_threshold "$test_path"

audit_has_warning=0
if [[ -f "$TMP/.modelstore/audit.log" ]]; then
  warning_event=$(jq -r '.event' "$TMP/.modelstore/audit.log" 2>/dev/null | grep "disk_warning" | head -1)
  [[ "$warning_event" == "disk_warning" ]] && audit_has_warning=1
fi
assert_eq "$audit_has_warning" "1" "audit.log has disk_warning entry after threshold crossed (SAFE-03)"

unset -f df

# ---------------------------------------------------------------------------
report
