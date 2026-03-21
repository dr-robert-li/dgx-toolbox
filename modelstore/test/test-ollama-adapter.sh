#!/usr/bin/env bash
# modelstore/test/test-ollama-adapter.sh — Unit tests for lib/ollama_adapter.sh
# Tests: server check, list, size, path, migrate guards (SAFE-01, SAFE-02, SAFE-06), recall guard
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELSTORE_LIB="${SCRIPT_DIR}/../lib"

PASS=0; FAIL=0
assert_eq() { if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1)); echo "  PASS: $3"; else FAIL=$((FAIL + 1)); echo "  FAIL: $3 (expected '$2', got '$1')"; fi; }
assert_ok() { if eval "$1" 2>/dev/null; then PASS=$((PASS + 1)); echo "  PASS: $2"; else FAIL=$((FAIL + 1)); echo "  FAIL: $2"; fi; }
report() { echo ""; echo "Results: $PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]; }

echo "=== Ollama Adapter Tests ==="

# ---------------------------------------------------------------------------
# Setup: temp environment
# ---------------------------------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.modelstore"
mkdir -p "$TMP/cold_mount"

# Write fake config
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

export HOME="$TMP"

# Source the adapter chain
# shellcheck source=../lib/common.sh
source "${MODELSTORE_LIB}/common.sh"
# shellcheck source=../lib/config.sh
source "${MODELSTORE_LIB}/config.sh"
# shellcheck source=../lib/ollama_adapter.sh
source "${MODELSTORE_LIB}/ollama_adapter.sh"

COLD_BASE="$TMP/cold_mount"
MOCK_JSON='{"models":[{"name":"llama3.2:latest","size":4000000000,"modified_at":"2026-01-01T00:00:00Z"}]}'

# ---------------------------------------------------------------------------
# Test 1: ollama_check_server returns 0 when systemctl succeeds (SAFE-06)
# ---------------------------------------------------------------------------
systemctl() { return 0; }
SERVER_RESULT=0
ollama_check_server 2>/dev/null || SERVER_RESULT=$?
unset -f systemctl
assert_eq "$SERVER_RESULT" "0" "ollama_check_server returns 0 when systemctl succeeds (SAFE-06)"

# ---------------------------------------------------------------------------
# Test 2: ollama_check_server returns 0 when curl succeeds but systemctl fails
# ---------------------------------------------------------------------------
systemctl() { return 1; }
curl() { return 0; }
SERVER_CURL_RESULT=0
ollama_check_server 2>/dev/null || SERVER_CURL_RESULT=$?
unset -f systemctl curl
assert_eq "$SERVER_CURL_RESULT" "0" "ollama_check_server returns 0 when curl succeeds (systemctl fails)"

# ---------------------------------------------------------------------------
# Test 3: ollama_check_server returns 1 when both systemctl and curl fail (SAFE-06)
# ---------------------------------------------------------------------------
systemctl() { return 1; }
curl() { return 1; }
SERVER_BOTH_FAIL=0
ollama_check_server 2>/dev/null || SERVER_BOTH_FAIL=$?
unset -f systemctl curl
if [[ "$SERVER_BOTH_FAIL" -ne 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: ollama_check_server returns non-zero when both systemctl and curl fail"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: ollama_check_server should return non-zero when both fail"
fi

# ---------------------------------------------------------------------------
# Test 4: ollama_list_models parses API response
# Override curl to return mock JSON
# ---------------------------------------------------------------------------
curl() {
  # Check for -sf flag and /api/tags URL in args
  echo "$MOCK_JSON"
  return 0
}
LIST_OUTPUT=$(ollama_list_models 2>/dev/null)
unset -f curl
LIST_HAS_NAME=0
LIST_HAS_SIZE=0
[[ "$LIST_OUTPUT" == *"llama3.2:latest"* ]] && LIST_HAS_NAME=1
[[ "$LIST_OUTPUT" == *"4000000000"* ]] && LIST_HAS_SIZE=1
assert_eq "$LIST_HAS_NAME" "1" "ollama_list_models output contains model name"
assert_eq "$LIST_HAS_SIZE" "1" "ollama_list_models output contains model size"

# ---------------------------------------------------------------------------
# Test 5: ollama_get_model_size extracts correct size from API response
# ---------------------------------------------------------------------------
curl() { echo "$MOCK_JSON"; return 0; }
SIZE_OUTPUT=$(ollama_get_model_size "llama3.2:latest" 2>/dev/null)
unset -f curl
assert_eq "$SIZE_OUTPUT" "4000000000" "ollama_get_model_size returns correct size in bytes"

# ---------------------------------------------------------------------------
# Test 6: ollama_get_model_path returns model name unchanged (API-only interface)
# ---------------------------------------------------------------------------
PATH_OUTPUT=$(ollama_get_model_path "llama3.2:latest" 2>/dev/null)
assert_eq "$PATH_OUTPUT" "llama3.2:latest" "ollama_get_model_path returns model name unchanged"

# ---------------------------------------------------------------------------
# Test 7: ollama_migrate_model blocks when server is active (SAFE-06)
# systemctl returns 0 (server running) — migrate must exit non-zero with error message
# ---------------------------------------------------------------------------
systemctl() { return 0; }
MIGRATE_BLOCKED=0
MIGRATE_LOG=$(ollama_migrate_model "llama3.2:latest" "$COLD_BASE" 2>&1) || MIGRATE_BLOCKED=$?
unset -f systemctl
BLOCKED_MSG=0
[[ "$MIGRATE_LOG" == *"Ollama server is active"* ]] && BLOCKED_MSG=1
if [[ "$MIGRATE_BLOCKED" -ne 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: ollama_migrate_model exits non-zero when server active (SAFE-06)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: ollama_migrate_model should exit non-zero when server active"
fi
assert_eq "$BLOCKED_MSG" "1" "ollama_migrate_model logs 'Ollama server is active' when blocked"

# ---------------------------------------------------------------------------
# Test 8: ollama_migrate_model calls check_cold_mounted when server is stopped (SAFE-01)
# systemctl returns 1 (stopped), curl returns 1 (stopped), mountpoint returns 1 (unmounted)
# ---------------------------------------------------------------------------
systemctl() { return 1; }
curl() { return 1; }
mountpoint() { return 1; }
MOUNT_FAIL_EXIT=0
(ollama_migrate_model "llama3.2:latest" "$COLD_BASE" 2>/dev/null) || MOUNT_FAIL_EXIT=$?
unset -f systemctl curl mountpoint
if [[ "$MOUNT_FAIL_EXIT" -ne 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: ollama_migrate_model exits non-zero when cold not mounted (SAFE-01)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: ollama_migrate_model should exit non-zero when cold not mounted"
fi

# ---------------------------------------------------------------------------
# Test 9: ollama_migrate_model checks space when server is stopped and cold mounted (SAFE-02)
# server stopped (both systemctl and curl return failure for server check),
# mountpoint succeeds, but df returns tiny space so check_space fails
# We use a separate curl mock that returns failure for /api/tags (server check)
# but returns model JSON when called with other args (get_model_size)
# Strategy: use a call counter — first call (server check) fails, rest succeed
# ---------------------------------------------------------------------------
systemctl() { return 1; }
_CURL_CALL=0
curl() {
  _CURL_CALL=$(( _CURL_CALL + 1 ))
  if [[ "$_CURL_CALL" -eq 1 ]]; then
    # First call is from ollama_check_server — return failure to indicate server is stopped
    return 1
  fi
  # Subsequent calls (from ollama_get_model_size) — return model data
  echo "$MOCK_JSON"
  return 0
}
mountpoint() { return 0; }
df() { echo "100"; }  # only 100 bytes available -> 90 usable, model is 4GB
SPACE_FAIL=0
ollama_migrate_model "llama3.2:latest" "$COLD_BASE" 2>/dev/null || SPACE_FAIL=$?
unset -f systemctl curl mountpoint df
unset _CURL_CALL
if [[ "$SPACE_FAIL" -ne 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: ollama_migrate_model returns non-zero on insufficient space (SAFE-02)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: ollama_migrate_model should return non-zero on insufficient space"
fi

# ---------------------------------------------------------------------------
# Test 10: ollama_recall_model blocks when server is active (SAFE-06)
# ---------------------------------------------------------------------------
systemctl() { return 0; }
RECALL_BLOCKED=0
RECALL_LOG=$(ollama_recall_model "llama3.2:latest" "$TMP" 2>&1) || RECALL_BLOCKED=$?
unset -f systemctl
RECALL_MSG=0
[[ "$RECALL_LOG" == *"Ollama server is active"* ]] && RECALL_MSG=1
if [[ "$RECALL_BLOCKED" -ne 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: ollama_recall_model exits non-zero when server active (SAFE-06)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: ollama_recall_model should exit non-zero when server active"
fi
assert_eq "$RECALL_MSG" "1" "ollama_recall_model logs 'Ollama server is active' when blocked"

# ---------------------------------------------------------------------------
# Test 11: No elevated privilege commands in ollama_adapter.sh
# ---------------------------------------------------------------------------
assert_ok "! grep -q 'sudo' modelstore/lib/ollama_adapter.sh" "No elevated privilege calls in ollama_adapter.sh"

# ---------------------------------------------------------------------------
# Test 12: No direct filesystem access to Ollama system paths
# ---------------------------------------------------------------------------
assert_ok "! grep -q '/usr/share/ollama' modelstore/lib/ollama_adapter.sh" "No direct /usr/share/ollama access in ollama_adapter.sh"

# ---------------------------------------------------------------------------
report
