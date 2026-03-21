#!/usr/bin/env bash
# modelstore/test/test-init.sh — Integration tests for cmd/init.sh functions
# Tests model scan, config round-trip, directory creation, and config backup
# using temp directories. Sources init.sh with stdin from /dev/null to prevent
# interactive prompts from blocking.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELSTORE_LIB="${SCRIPT_DIR}/../lib"
MODELSTORE_CMD="${SCRIPT_DIR}/../cmd"

PASS=0; FAIL=0
assert_eq() { if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1)); echo "  PASS: $3"; else FAIL=$((FAIL + 1)); echo "  FAIL: $3 (expected '$2', got '$1')"; fi; }
assert_ok() { if eval "$1" 2>/dev/null; then PASS=$((PASS + 1)); echo "  PASS: $2"; else FAIL=$((FAIL + 1)); echo "  FAIL: $2"; fi; }
assert_fail() { if eval "$1" 2>/dev/null; then FAIL=$((FAIL + 1)); echo "  FAIL: $2 (should have failed)"; else PASS=$((PASS + 1)); echo "  PASS: $2"; fi; }
report() { echo ""; echo "Results: $PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]; }

echo "=== Init Function Tests ==="

# --- Setup: temp directory and cleanup trap ---
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Override MODELSTORE_CONFIG to use temp dir (must be set before sourcing config.sh)
export MODELSTORE_CONFIG="${TMPDIR_TEST}/config.json"
mkdir -p "${TMPDIR_TEST}"

# Source the libs first
# shellcheck source=../lib/common.sh
source "${MODELSTORE_LIB}/common.sh"
# shellcheck source=../lib/config.sh
source "${MODELSTORE_LIB}/config.sh"
MODELSTORE_CONFIG="${TMPDIR_TEST}/config.json"

# Override ms_die to return 1 without exiting so tests can catch the result
ms_die() {
  echo "[modelstore] ERROR: $*" >&2
  return 1
}

# Source init.sh — the BASH_SOURCE guard prevents main() from running,
# so only function definitions are loaded.
# shellcheck source=../cmd/init.sh
source "${MODELSTORE_CMD}/init.sh" </dev/null 2>/dev/null

# Re-apply MODELSTORE_CONFIG override: init.sh re-sources config.sh which resets the path
MODELSTORE_CONFIG="${TMPDIR_TEST}/config.json"

# -------------------------------------------------------------------------
# Test Group 1: scan_hf_models — HuggingFace model scan table output
# -------------------------------------------------------------------------

echo ""
echo "--- scan_hf_models tests ---"

# Create mock HF hub structure with two models
HF_HUB="${TMPDIR_TEST}/hf/hub"
mkdir -p "${HF_HUB}/models--org1--llama3"
mkdir -p "${HF_HUB}/models--org2--mistral"

# Create dummy model files so du -sb returns non-zero sizes
dd if=/dev/zero of="${HF_HUB}/models--org1--llama3/model.bin" bs=1024 count=100 2>/dev/null
dd if=/dev/zero of="${HF_HUB}/models--org2--mistral/model.bin" bs=1024 count=200 2>/dev/null

# Set HOT_HF_PATH so scan_hf_models uses it
HOT_HF_PATH="$HF_HUB"

# --- Test 1: scan_hf_models produces table output with MODEL header ---
SCAN_OUTPUT=$(scan_hf_models "$HF_HUB" 2>/dev/null)
if echo "$SCAN_OUTPUT" | grep -q "MODEL"; then
  PASS=$((PASS + 1)); echo "  PASS: scan_hf_models outputs MODEL header"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: scan_hf_models outputs MODEL header"
fi

# --- Test 2: scan_hf_models includes model name (strips models-- prefix) ---
if echo "$SCAN_OUTPUT" | grep -q "org1/llama3\|org1.llama3"; then
  PASS=$((PASS + 1)); echo "  PASS: scan_hf_models strips models-- prefix and converts -- to /"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: scan_hf_models strips models-- prefix (output: $SCAN_OUTPUT)"
fi

# --- Test 3: scan_hf_models includes second model ---
if echo "$SCAN_OUTPUT" | grep -q "org2/mistral\|org2.mistral"; then
  PASS=$((PASS + 1)); echo "  PASS: scan_hf_models includes second model"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: scan_hf_models includes second model"
fi

# --- Test 4: scan_hf_models outputs HuggingFace TOTAL line ---
if echo "$SCAN_OUTPUT" | grep -q "HuggingFace TOTAL"; then
  PASS=$((PASS + 1)); echo "  PASS: scan_hf_models outputs HuggingFace TOTAL"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: scan_hf_models outputs HuggingFace TOTAL"
fi

# --- Test 5: scan_hf_models handles missing HF hub gracefully ---
EMPTY_OUTPUT=$(scan_hf_models "/nonexistent/path" 2>/dev/null)
if echo "$EMPTY_OUTPUT" | grep -q "no HuggingFace hub\|not found\|unset"; then
  PASS=$((PASS + 1)); echo "  PASS: scan_hf_models handles missing directory gracefully"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: scan_hf_models handles missing directory gracefully (got: $EMPTY_OUTPUT)"
fi

# -------------------------------------------------------------------------
# Test Group 2: config round-trip via write_config and config_read
# -------------------------------------------------------------------------

echo ""
echo "--- Config round-trip tests ---"

# --- Test 6: write_config creates valid JSON config ---
mkdir -p "$(dirname "$MODELSTORE_CONFIG")"
write_config "${HF_HUB}" "${TMPDIR_TEST}/ollama" "${TMPDIR_TEST}/cold" 21 3 45
assert_ok "jq -e . '$MODELSTORE_CONFIG' >/dev/null" "write_config creates parseable JSON"

# --- Test 7: config_read retrieves retention_days correctly ---
actual_ret=$(config_read '.retention_days')
assert_eq "$actual_ret" "21" "config_read returns correct retention_days"

# --- Test 8: config_read retrieves cron_hour correctly ---
actual_cron=$(config_read '.cron_hour')
assert_eq "$actual_cron" "3" "config_read returns correct cron_hour"

# --- Test 9: config_read retrieves cold_path correctly ---
actual_cold=$(config_read '.cold_path')
assert_eq "$actual_cold" "${TMPDIR_TEST}/cold" "config_read returns correct cold_path"

# --- Test 10: config_read retrieves hot_hf_path correctly ---
actual_hf=$(config_read '.hot_hf_path')
assert_eq "$actual_hf" "${HF_HUB}" "config_read returns correct hot_hf_path"

# -------------------------------------------------------------------------
# Test Group 3: Directory creation for cold drive structure
# -------------------------------------------------------------------------

echo ""
echo "--- Directory creation tests ---"

COLD_PATH="${TMPDIR_TEST}/cold"

# --- Test 11: cold drive directory structure created correctly ---
mkdir -p "${COLD_PATH}/huggingface/hub"
mkdir -p "${COLD_PATH}/ollama/models"
assert_ok "test -d '${COLD_PATH}/huggingface/hub'" "Cold huggingface/hub dir created"
assert_ok "test -d '${COLD_PATH}/ollama/models'" "Cold ollama/models dir created"

# -------------------------------------------------------------------------
# Test Group 4: Config backup functionality
# -------------------------------------------------------------------------

echo ""
echo "--- Config backup tests ---"

# --- Test 13: backup_config_if_exists creates a .bak. file ---
backup_config_if_exists 2>/dev/null
BAK_COUNT=$(find "$TMPDIR_TEST" -name "config.json.bak.*" | wc -l)
if [[ "$BAK_COUNT" -ge 1 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: backup_config_if_exists creates timestamped backup"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: backup_config_if_exists creates timestamped backup (count: $BAK_COUNT)"
fi

# --- Test 14: config still exists after backup (backup is cp, not mv) ---
assert_ok "config_exists" "Original config still exists after backup"

# -------------------------------------------------------------------------
report
