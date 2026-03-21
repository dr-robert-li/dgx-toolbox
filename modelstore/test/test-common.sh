#!/usr/bin/env bash
# modelstore/test/test-common.sh — Unit tests for modelstore/lib/common.sh
# Tests logging, filesystem validation, and space check functions.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELSTORE_LIB="${SCRIPT_DIR}/../lib"

PASS=0; FAIL=0
assert_eq() { if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1)); echo "  PASS: $3"; else FAIL=$((FAIL + 1)); echo "  FAIL: $3 (expected '$2', got '$1')"; fi; }
assert_ok() { if eval "$1" 2>/dev/null; then PASS=$((PASS + 1)); echo "  PASS: $2"; else FAIL=$((FAIL + 1)); echo "  FAIL: $2"; fi; }
report() { echo ""; echo "Results: $PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]; }

echo "=== Common Tests ==="

# Source common.sh
# shellcheck source=../lib/common.sh
source "${MODELSTORE_LIB}/common.sh"

# --- Test 1: ms_log writes to stderr with [modelstore] prefix ---
LOG_OUTPUT=$(ms_log "hello" 2>&1)
assert_eq "$LOG_OUTPUT" "[modelstore] hello" "ms_log writes [modelstore] hello to stderr"

# --- Test 2: ms_die writes error to stderr ---
DIE_OUTPUT=$(ms_die "fail" 2>&1) || true
assert_eq "$DIE_OUTPUT" "[modelstore] ERROR: fail" "ms_die writes [modelstore] ERROR: fail to stderr"

# --- Test 3: ms_die exits with code 1 ---
DIE_EXIT=0
(ms_die "test exit" 2>/dev/null) || DIE_EXIT=$?
assert_eq "$DIE_EXIT" "1" "ms_die exits with code 1"

# --- Test 4: validate_cold_fs accepts ext4 ---
# Override findmnt via bash function for testing
findmnt() { echo "ext4"; }
RESULT=0
validate_cold_fs "/any/path" 2>/dev/null || RESULT=$?
if [[ "$RESULT" -eq 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: validate_cold_fs accepts ext4"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: validate_cold_fs accepts ext4 (returned $RESULT)"
fi

# --- Test 5: validate_cold_fs accepts xfs ---
findmnt() { echo "xfs"; }
RESULT=0
validate_cold_fs "/any/path" 2>/dev/null || RESULT=$?
if [[ "$RESULT" -eq 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: validate_cold_fs accepts xfs"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: validate_cold_fs accepts xfs (returned $RESULT)"
fi

# --- Test 6: validate_cold_fs accepts btrfs ---
findmnt() { echo "btrfs"; }
RESULT=0
validate_cold_fs "/any/path" 2>/dev/null || RESULT=$?
if [[ "$RESULT" -eq 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: validate_cold_fs accepts btrfs"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: validate_cold_fs accepts btrfs (returned $RESULT)"
fi

# --- Test 7: validate_cold_fs rejects exfat ---
findmnt() { echo "exfat"; }
RESULT=0
validate_cold_fs "/any/path" 2>/dev/null || RESULT=$?
if [[ "$RESULT" -ne 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: validate_cold_fs rejects exfat"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: validate_cold_fs rejects exfat (should have returned non-zero)"
fi

# --- Test 8: validate_cold_fs rejects vfat ---
findmnt() { echo "vfat"; }
RESULT=0
validate_cold_fs "/any/path" 2>/dev/null || RESULT=$?
if [[ "$RESULT" -ne 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: validate_cold_fs rejects vfat"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: validate_cold_fs rejects vfat (should have returned non-zero)"
fi

# --- Test 9: validate_cold_fs rejects ntfs ---
findmnt() { echo "ntfs"; }
RESULT=0
validate_cold_fs "/any/path" 2>/dev/null || RESULT=$?
if [[ "$RESULT" -ne 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: validate_cold_fs rejects ntfs"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: validate_cold_fs rejects ntfs (should have returned non-zero)"
fi

# Unset mock findmnt to restore system behavior
unset -f findmnt

# --- Test 10: check_space returns 0 when space is sufficient ---
# Override df to return 100MB available
df() { echo "104857600"; }
RESULT=0
check_space "/any/path" 1000 || RESULT=$?  # Need 1000 bytes, have ~94MB usable
if [[ "$RESULT" -eq 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: check_space returns 0 when sufficient space"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: check_space returns 0 when sufficient space (returned $RESULT)"
fi

# --- Test 11: check_space returns 1 when space is insufficient ---
df() { echo "100"; }  # Only 100 bytes available, 90 bytes usable
RESULT=0
check_space "/any/path" 1000 2>/dev/null || RESULT=$?  # Need 1000 bytes, have 90 usable
if [[ "$RESULT" -ne 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: check_space returns 1 when insufficient space"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: check_space returns 1 when insufficient space (should have returned non-zero)"
fi

# Unset mock df
unset -f df

report
