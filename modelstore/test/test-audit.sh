#!/usr/bin/env bash
# modelstore/test/test-audit.sh — Tests for lib/audit.sh
# Covers: MIGR-08 (audit logging for all events)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELSTORE_LIB="${SCRIPT_DIR}/../lib"

PASS=0; FAIL=0
assert_eq() { if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1)); echo "  PASS: $3"; else FAIL=$((FAIL + 1)); echo "  FAIL: $3 (expected '$2', got '$1')"; fi; }
assert_ok() { if eval "$1" 2>/dev/null; then PASS=$((PASS + 1)); echo "  PASS: $2"; else FAIL=$((FAIL + 1)); echo "  FAIL: $2"; fi; }
report() { echo ""; echo "Results: $PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]; }

echo "=== Audit Tests ==="

# ---------------------------------------------------------------------------
# Setup: temp environment
# ---------------------------------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.modelstore"
export HOME="$TMP"

# Source audit.sh (which sources common.sh)
source "${MODELSTORE_LIB}/common.sh"
source "${MODELSTORE_LIB}/config.sh"

# Write minimal config so config.sh doesn't complain when sourced
cat > "$TMP/.modelstore/config.json" <<ENDCONFIG
{
  "version": 1,
  "hot_hf_path": "${TMP}/hf_cache",
  "hot_ollama_path": "${TMP}/ollama_models",
  "cold_path": "${TMP}/cold_mount",
  "retention_days": 14,
  "cron_hour": 2,
  "backup_retention_days": 30,
  "created_at": "2026-01-01T00:00:00Z",
  "updated_at": "2026-01-01T00:00:00Z"
}
ENDCONFIG

source "${MODELSTORE_LIB}/audit.sh"

# Convenience: reset audit log between tests
reset_audit() { rm -f "$AUDIT_LOG" "$AUDIT_LOCK"; }

# ---------------------------------------------------------------------------
# Test 1: MIGR-08 — migrate event is logged to audit.log
# ---------------------------------------------------------------------------
echo ""
echo "--- Test MIGR-08: test_migrate_logged ---"

reset_audit
audit_log "migrate" "/path/to/model" 1073741824 "/path/to/model" "/cold/hf/model" 30 "cron"

logged_event=""
if [[ -f "$AUDIT_LOG" ]]; then
  logged_event=$(jq -r '.event' "$AUDIT_LOG" 2>/dev/null || echo "")
fi
assert_eq "$logged_event" "migrate" "audit.log contains event=migrate (MIGR-08)"

# Also verify it's valid JSON
valid_json=0
jq -e '.' "$AUDIT_LOG" >/dev/null 2>&1 && valid_json=1
assert_eq "$valid_json" "1" "audit.log entry is valid JSON (MIGR-08)"

# ---------------------------------------------------------------------------
# Test 2: recall event is logged
# ---------------------------------------------------------------------------
echo ""
echo "--- Test MIGR-08: test_recall_logged ---"

reset_audit
audit_log "recall" "/path/to/model" 512000000 "/cold/hf/model" "/path/to/model" 15 "auto"

recall_event=""
if [[ -f "$AUDIT_LOG" ]]; then
  recall_event=$(jq -r '.event' "$AUDIT_LOG" 2>/dev/null || echo "")
fi
assert_eq "$recall_event" "recall" "audit.log contains event=recall (MIGR-08)"

# ---------------------------------------------------------------------------
# Test 3: failure event has non-null error field
# ---------------------------------------------------------------------------
echo ""
echo "--- Test MIGR-08: test_failure_logged ---"

reset_audit
audit_log "fail" "/path/to/broken/model" 0 "/path/to/broken/model" "" 0 "manual" "migration failed: rsync returned 23"

fail_event=""
fail_error=""
if [[ -f "$AUDIT_LOG" ]]; then
  fail_event=$(jq -r '.event' "$AUDIT_LOG" 2>/dev/null || echo "")
  fail_error=$(jq -r '.error' "$AUDIT_LOG" 2>/dev/null || echo "null")
fi
assert_eq "$fail_event" "fail" "audit.log contains event=fail (MIGR-08)"

error_not_null=0
[[ "$fail_error" != "null" && -n "$fail_error" ]] && error_not_null=1
assert_eq "$error_not_null" "1" "fail event has non-null error field (MIGR-08)"

# ---------------------------------------------------------------------------
# Test 4: Annual rotation — old log renamed when year changes
# ---------------------------------------------------------------------------
echo ""
echo "--- Test MIGR-08: test_rotation ---"

reset_audit

# Create an audit.log with a 2025 timestamp (old year)
old_year_entry='{"timestamp":"2025-12-31T23:00:00Z","event":"migrate","model":"/old","size_bytes":0,"source":"","dest":"","duration_sec":0,"trigger":"cron","error":null}'
echo "$old_year_entry" > "$AUDIT_LOG"

# Call audit_log — rotation should fire because log year (2025) != current year (2026)
audit_log "migrate" "/new/model" 100 "/src" "/dst" 5 "manual"

# Old log should be renamed to audit.2025.log
rotated_log="${AUDIT_LOG%.log}.2025.log"
rotation_ok=0
[[ -f "$rotated_log" ]] && rotation_ok=1
assert_eq "$rotation_ok" "1" "old audit log rotated to audit.2025.log (MIGR-08)"

# New audit.log should exist with the new entry
new_log_ok=0
if [[ -f "$AUDIT_LOG" ]]; then
  new_year=$(jq -r '.timestamp' "$AUDIT_LOG" 2>/dev/null | cut -c1-4)
  current_year=$(date +%Y)
  [[ "$new_year" == "$current_year" ]] && new_log_ok=1
fi
assert_eq "$new_log_ok" "1" "new audit.log created with current year timestamp after rotation (MIGR-08)"

# ---------------------------------------------------------------------------
# Test 5: Concurrent audit_log writes do not corrupt the log
# ---------------------------------------------------------------------------
echo ""
echo "--- Test MIGR-08: test_flock_prevents_corruption ---"

reset_audit

# Run two concurrent audit_log calls
audit_log "migrate" "/model/one" 100 "/src1" "/dst1" 1 "cron" &
pid1=$!
audit_log "recall" "/model/two" 200 "/src2" "/dst2" 2 "auto" &
pid2=$!
wait "$pid1" "$pid2"

# Count lines in audit.log
line_count=0
if [[ -f "$AUDIT_LOG" ]]; then
  line_count=$(wc -l < "$AUDIT_LOG" 2>/dev/null || echo 0)
fi
assert_eq "$line_count" "2" "concurrent audit_log writes produce exactly 2 valid lines (MIGR-08)"

# Verify both lines are valid JSON
valid_lines=0
if [[ -f "$AUDIT_LOG" ]]; then
  valid_lines=$(jq -c '.' "$AUDIT_LOG" 2>/dev/null | wc -l || echo 0)
fi
assert_eq "$valid_lines" "2" "both concurrent audit.log lines are valid JSON (MIGR-08)"

# ---------------------------------------------------------------------------
report
