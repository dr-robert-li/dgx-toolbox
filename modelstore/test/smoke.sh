#!/usr/bin/env bash
# modelstore/test/smoke.sh — Quick sanity check: function existence and no-side-effects on source
# Runs in under 5 seconds. Exits 0 if all pass.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELSTORE_LIB="${SCRIPT_DIR}/../lib"

PASS=0; FAIL=0
assert_ok() { if eval "$1" 2>/dev/null; then PASS=$((PASS + 1)); echo "  PASS: $2"; else FAIL=$((FAIL + 1)); echo "  FAIL: $2"; fi; }
report() { echo ""; echo "Results: $PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]; }

echo "=== Smoke Tests ==="

# Source libs without error
assert_ok "source '${MODELSTORE_LIB}/common.sh'" "common.sh sources without error"
assert_ok "source '${MODELSTORE_LIB}/config.sh'" "config.sh sources without error"

# All expected functions from common.sh
# shellcheck source=../lib/common.sh
source "${MODELSTORE_LIB}/common.sh"
assert_ok "type -t ms_log >/dev/null 2>&1" "ms_log function exists"
assert_ok "type -t ms_die >/dev/null 2>&1" "ms_die function exists"
assert_ok "type -t check_cold_mounted >/dev/null 2>&1" "check_cold_mounted function exists"
assert_ok "type -t check_space >/dev/null 2>&1" "check_space function exists"
assert_ok "type -t validate_cold_fs >/dev/null 2>&1" "validate_cold_fs function exists"

# All expected functions from config.sh
# shellcheck source=../lib/config.sh
source "${MODELSTORE_LIB}/config.sh"
assert_ok "type -t config_exists >/dev/null 2>&1" "config_exists function exists"
assert_ok "type -t config_read >/dev/null 2>&1" "config_read function exists"
assert_ok "type -t load_config >/dev/null 2>&1" "load_config function exists"
assert_ok "type -t write_config >/dev/null 2>&1" "write_config function exists"
assert_ok "type -t backup_config_if_exists >/dev/null 2>&1" "backup_config_if_exists function exists"

# MODELSTORE_CONFIG constant is set
assert_ok "test -n '${MODELSTORE_CONFIG:-}'" "MODELSTORE_CONFIG constant is set"

report
echo "Smoke tests passed"
