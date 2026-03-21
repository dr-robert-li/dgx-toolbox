#!/usr/bin/env bash
# modelstore/test/test-config.sh — Unit tests for modelstore/lib/config.sh
# Tests config read/write round-trip, load_config, and backup functions.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELSTORE_LIB="${SCRIPT_DIR}/../lib"

PASS=0; FAIL=0
assert_eq() { if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1)); echo "  PASS: $3"; else FAIL=$((FAIL + 1)); echo "  FAIL: $3 (expected '$2', got '$1')"; fi; }
assert_ok() { if eval "$1" 2>/dev/null; then PASS=$((PASS + 1)); echo "  PASS: $2"; else FAIL=$((FAIL + 1)); echo "  FAIL: $2"; fi; }
assert_fail() { if eval "$1" 2>/dev/null; then FAIL=$((FAIL + 1)); echo "  FAIL: $2 (should have failed)"; else PASS=$((PASS + 1)); echo "  PASS: $2"; fi; }
report() { echo ""; echo "Results: $PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]; }

echo "=== Config Tests ==="

# --- Setup: override MODELSTORE_CONFIG to use a temp directory ---
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Source config.sh, then override the config path to use temp dir
# shellcheck source=../lib/config.sh
source "${MODELSTORE_LIB}/config.sh"
MODELSTORE_CONFIG="${TMPDIR_TEST}/config.json"

# --- Test 1: config_exists returns false when no config file ---
assert_fail "config_exists" "config_exists returns false when no config"

# --- Test 2: write_config creates valid JSON ---
mkdir -p "$(dirname "$MODELSTORE_CONFIG")"
write_config "/tmp/hf" "/tmp/ollama" "/tmp/cold" 14 2 30
assert_ok "jq -e . '$MODELSTORE_CONFIG' >/dev/null 2>&1" "write_config creates valid JSON"

# --- Test 3: config_read .version returns 1 ---
actual_version=$(config_read '.version')
assert_eq "$actual_version" "1" "config_read .version returns 1"

# --- Test 4: config_read .hot_hf_path returns /tmp/hf ---
actual_hf=$(config_read '.hot_hf_path')
assert_eq "$actual_hf" "/tmp/hf" "config_read .hot_hf_path returns /tmp/hf"

# --- Test 5: config_read .retention_days returns 14 ---
actual_ret=$(config_read '.retention_days')
assert_eq "$actual_ret" "14" "config_read .retention_days returns 14"

# --- Test 6: config_read .cron_hour returns 2 ---
actual_cron=$(config_read '.cron_hour')
assert_eq "$actual_cron" "2" "config_read .cron_hour returns 2"

# --- Test 7: config_read .cold_path returns /tmp/cold ---
actual_cold=$(config_read '.cold_path')
assert_eq "$actual_cold" "/tmp/cold" "config_read .cold_path returns /tmp/cold"

# --- Test 8: config_exists returns true after write ---
assert_ok "config_exists" "config_exists returns true after write_config"

# --- Test 9: load_config sets variables correctly ---
load_config
assert_eq "$HOT_HF_PATH" "/tmp/hf" "load_config sets HOT_HF_PATH"
assert_eq "$COLD_PATH" "/tmp/cold" "load_config sets COLD_PATH"
assert_eq "$RETENTION_DAYS" "14" "load_config sets RETENTION_DAYS"

# --- Test 10: load_config exits non-zero when config file missing ---
# Run in subshell to capture exit without terminating this test script
MISSING_CONFIG="${TMPDIR_TEST}/nonexistent.json"
LOAD_RESULT=0
(
  MODELSTORE_CONFIG="${MISSING_CONFIG}"
  source "${MODELSTORE_LIB}/config.sh"
  MODELSTORE_CONFIG="${MISSING_CONFIG}"
  load_config
) 2>/dev/null || LOAD_RESULT=$?
if [[ "$LOAD_RESULT" -ne 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: load_config exits non-zero when config missing"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: load_config exits non-zero when config missing (should have exited non-zero)"
fi

# --- Test 11: backup_config_if_exists creates a .bak. file ---
backup_config_if_exists 2>/dev/null
BAK_COUNT=$(find "$TMPDIR_TEST" -name "config.json.bak.*" | wc -l)
if [[ "$BAK_COUNT" -ge 1 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: backup_config_if_exists creates backup file"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: backup_config_if_exists creates backup file (no .bak. file found)"
fi

# --- Test 12: chmod 600 applied to config ---
CONFIG_PERMS=$(stat -c '%a' "$MODELSTORE_CONFIG" 2>/dev/null)
assert_eq "$CONFIG_PERMS" "600" "write_config sets chmod 600 on config file"

report
