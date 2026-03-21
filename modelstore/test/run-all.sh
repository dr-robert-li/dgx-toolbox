#!/usr/bin/env bash
# modelstore/test/run-all.sh — Run all test scripts and report results
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_SCRIPTS=()

run_test_script() {
  local script="$1"
  local name="$2"
  echo ""
  echo "--- Running: $name ---"
  if bash "$script"; then
    echo "--- $name: OK ---"
  else
    echo "--- $name: FAILED ---"
    FAILED_SCRIPTS+=("$name")
    return 1
  fi
}

# Run all test scripts
run_test_script "${SCRIPT_DIR}/smoke.sh"              "smoke.sh"              || true
run_test_script "${SCRIPT_DIR}/test-config.sh"        "test-config.sh"        || true
run_test_script "${SCRIPT_DIR}/test-common.sh"        "test-common.sh"        || true
run_test_script "${SCRIPT_DIR}/test-fs-validation.sh" "test-fs-validation.sh" || true
run_test_script "${SCRIPT_DIR}/test-init.sh"          "test-init.sh"          || true
run_test_script "${SCRIPT_DIR}/test-hf-adapter.sh"    "test-hf-adapter.sh"    || true
run_test_script "${SCRIPT_DIR}/test-ollama-adapter.sh" "test-ollama-adapter.sh" || true
run_test_script "${SCRIPT_DIR}/test-watcher.sh"        "test-watcher.sh"        || true
run_test_script "${SCRIPT_DIR}/test-status.sh"         "test-status.sh"         || true
run_test_script "${SCRIPT_DIR}/test-revert.sh"         "test-revert.sh"         || true

echo ""
echo "================================"
echo "=== Test Suite Summary ==="
echo "================================"

if [[ ${#FAILED_SCRIPTS[@]} -eq 0 ]]; then
  echo "All test scripts passed"
  exit 0
else
  echo "Failed scripts:"
  for s in "${FAILED_SCRIPTS[@]}"; do
    echo "  - $s"
  done
  exit 1
fi
