#!/usr/bin/env bash
# scripts/test-data-integration.sh — Tests for DATA-01, DATA-02, DATA-03
# Covers: local dataset discovery, HF model selection, screen-data.sh behavior
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0; FAIL=0
assert_ok()   { if eval "$1" 2>/dev/null; then PASS=$((PASS+1)); echo "  PASS: $2"; else FAIL=$((FAIL+1)); echo "  FAIL: $2"; fi; }
assert_fail() { if eval "$1" 2>/dev/null; then FAIL=$((FAIL+1)); echo "  FAIL: $2 (should have failed)"; else PASS=$((PASS+1)); echo "  PASS: $2"; fi; }
assert_grep() { if grep -q "$1" "$2" 2>/dev/null; then PASS=$((PASS+1)); echo "  PASS: $3"; else FAIL=$((FAIL+1)); echo "  FAIL: $3 (pattern '$1' not found in $2)"; fi; }
report() { echo ""; echo "PASS: $PASS / TOTAL: $((PASS+FAIL))"; [[ $FAIL -eq 0 ]]; }

LAUNCHER="${REPO_ROOT}/karpathy-autoresearch/launch-autoresearch.sh"
SYNC_LAUNCHER="${REPO_ROOT}/karpathy-autoresearch/launch-autoresearch-sync.sh"
SCREEN_DATA="${REPO_ROOT}/scripts/screen-data.sh"

echo "=== Data Integration Tests ==="
echo ""

# ============================================================
# DATA-01: Local dataset auto-discovery in launcher
# ============================================================
echo "--- DATA-01: Local dataset auto-discovery ---"

test_option_6_in_menu() {
  assert_grep "Local datasets (auto-discovered)" "$LAUNCHER" \
    "Option 6 'Local datasets (auto-discovered)' present in launcher menu"
}

test_discover_local_datasets_function() {
  assert_grep "_discover_local_datasets" "$LAUNCHER" \
    "_discover_local_datasets function referenced in launcher"
}

test_sync_local_datasets_source() {
  assert_grep "local-datasets)" "$SYNC_LAUNCHER" \
    "local-datasets case present in sync launcher"
}

test_option_6_in_menu
test_discover_local_datasets_function
test_sync_local_datasets_source

echo ""

# ============================================================
# DATA-02: HF cache model selection
# ============================================================
echo "--- DATA-02: HF cache model selection ---"

test_hf_model_selection_function() {
  assert_grep "_select_hf_model" "$LAUNCHER" \
    "_select_hf_model function referenced in launcher"
}

test_sync_base_model_env() {
  assert_grep "AUTORESEARCH_BASE_MODEL" "$SYNC_LAUNCHER" \
    "AUTORESEARCH_BASE_MODEL env var referenced in sync launcher"
}

test_hf_model_selection_function
test_sync_base_model_env

echo ""

# ============================================================
# DATA-03: screen-data.sh behavior
# ============================================================
echo "--- DATA-03: screen-data.sh ---"

test_screen_data_exists() {
  assert_ok "test -x '${SCREEN_DATA}'" \
    "screen-data.sh exists and is executable"
}

test_screen_data_syntax() {
  assert_ok "bash -n '${SCREEN_DATA}'" \
    "screen-data.sh has valid bash syntax"
}

test_screen_data_no_harness() {
  # Set HARNESS_URL to a port with nothing listening; should exit non-zero
  # and print "not reachable" to stderr
  local tmpdir
  tmpdir=$(mktemp -d)
  local dummy_input="${tmpdir}/dummy.txt"
  echo "hello world" > "$dummy_input"
  local stderr_out
  stderr_out="${tmpdir}/stderr.txt"
  local exit_code=0
  HARNESS_URL="http://localhost:59999" \
  HARNESS_API_KEY="test-key" \
    bash "${SCREEN_DATA}" "$dummy_input" "$tmpdir" 2>"$stderr_out" || exit_code=$?
  if [ "$exit_code" -ne 0 ] && grep -q "not reachable" "$stderr_out" 2>/dev/null; then
    PASS=$((PASS+1)); echo "  PASS: screen-data.sh exits non-zero and prints 'not reachable' when harness down"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: screen-data.sh did not properly error when harness unreachable (exit=$exit_code)"
    if [ -f "$stderr_out" ]; then echo "  stderr: $(cat "$stderr_out")"; fi
  fi
  rm -rf "$tmpdir"
}

test_screen_data_no_api_key() {
  # Unset HARNESS_API_KEY; should exit non-zero and print "HARNESS_API_KEY" to stderr
  local tmpdir
  tmpdir=$(mktemp -d)
  local dummy_input="${tmpdir}/dummy.txt"
  echo "test record" > "$dummy_input"
  local stderr_out="${tmpdir}/stderr.txt"
  local exit_code=0
  env -u HARNESS_API_KEY \
    HARNESS_URL="http://localhost:59999" \
    bash "${SCREEN_DATA}" "$dummy_input" "$tmpdir" 2>"$stderr_out" || exit_code=$?
  if [ "$exit_code" -ne 0 ] && grep -q "HARNESS_API_KEY" "$stderr_out" 2>/dev/null; then
    PASS=$((PASS+1)); echo "  PASS: screen-data.sh exits non-zero and mentions HARNESS_API_KEY when key unset"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: screen-data.sh did not properly error when HARNESS_API_KEY unset (exit=$exit_code)"
    if [ -f "$stderr_out" ]; then echo "  stderr: $(cat "$stderr_out")"; fi
  fi
  rm -rf "$tmpdir"
}

test_screen_data_exists
test_screen_data_syntax
test_screen_data_no_harness
test_screen_data_no_api_key

echo ""
report
