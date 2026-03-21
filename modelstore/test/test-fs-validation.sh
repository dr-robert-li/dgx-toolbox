#!/usr/bin/env bash
# modelstore/test/test-fs-validation.sh — Filesystem type rejection/acceptance tests
# Tests validate_cold_fs from lib/common.sh using a mocked findmnt function.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELSTORE_LIB="${SCRIPT_DIR}/../lib"

PASS=0; FAIL=0
assert_ok() { if eval "$1" 2>/dev/null; then PASS=$((PASS + 1)); echo "  PASS: $2"; else FAIL=$((FAIL + 1)); echo "  FAIL: $2"; fi; }
assert_fail() { if eval "$1" 2>/dev/null; then FAIL=$((FAIL + 1)); echo "  FAIL: $2 (should have failed)"; else PASS=$((PASS + 1)); echo "  PASS: $2"; fi; }
report() { echo ""; echo "Results: $PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]; }

echo "=== Filesystem Validation Tests ==="

# Source common.sh to get validate_cold_fs and ms_die
# shellcheck source=../lib/common.sh
source "${MODELSTORE_LIB}/common.sh"

# Override ms_die to return 1 without exiting so tests can catch the result
ms_die() {
  echo "[modelstore] ERROR: $*" >&2
  return 1
}

# --- Test 1: validate_cold_fs accepts ext4 ---
findmnt() { echo "ext4"; }
RESULT=0
validate_cold_fs "/fake/path" 2>/dev/null || RESULT=$?
if [[ "$RESULT" -eq 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: validate_cold_fs accepts ext4"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: validate_cold_fs accepts ext4 (returned $RESULT)"
fi

# --- Test 2: validate_cold_fs accepts xfs ---
findmnt() { echo "xfs"; }
RESULT=0
validate_cold_fs "/fake/path" 2>/dev/null || RESULT=$?
if [[ "$RESULT" -eq 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: validate_cold_fs accepts xfs"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: validate_cold_fs accepts xfs (returned $RESULT)"
fi

# --- Test 3: validate_cold_fs accepts btrfs ---
findmnt() { echo "btrfs"; }
RESULT=0
validate_cold_fs "/fake/path" 2>/dev/null || RESULT=$?
if [[ "$RESULT" -eq 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: validate_cold_fs accepts btrfs"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: validate_cold_fs accepts btrfs (returned $RESULT)"
fi

# --- Test 4: validate_cold_fs rejects exfat (no symlink support) ---
findmnt() { echo "exfat"; }
RESULT=0
STDERR_OUT=$(validate_cold_fs "/fake/path" 2>&1) || RESULT=$?
if [[ "$RESULT" -ne 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: validate_cold_fs rejects exfat (returned non-zero)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: validate_cold_fs rejects exfat (should have returned non-zero)"
fi
# Verify error message mentions symlink support
if echo "$STDERR_OUT" | grep -qi "symlink\|not supported"; then
  PASS=$((PASS + 1)); echo "  PASS: exfat rejection message mentions symlink/not supported"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: exfat rejection message does not mention symlink/not supported (got: $STDERR_OUT)"
fi

# --- Test 5: validate_cold_fs rejects vfat ---
findmnt() { echo "vfat"; }
RESULT=0
validate_cold_fs "/fake/path" 2>/dev/null || RESULT=$?
if [[ "$RESULT" -ne 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: validate_cold_fs rejects vfat"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: validate_cold_fs rejects vfat (should have returned non-zero)"
fi

# --- Test 6: validate_cold_fs rejects ntfs ---
findmnt() { echo "ntfs"; }
RESULT=0
validate_cold_fs "/fake/path" 2>/dev/null || RESULT=$?
if [[ "$RESULT" -ne 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: validate_cold_fs rejects ntfs"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: validate_cold_fs rejects ntfs (should have returned non-zero)"
fi

# --- Test 7: validate_cold_fs rejects empty string (unmounted path) ---
findmnt() { echo ""; }
RESULT=0
validate_cold_fs "/fake/path" 2>/dev/null || RESULT=$?
if [[ "$RESULT" -ne 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: validate_cold_fs rejects empty fstype (unmounted)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: validate_cold_fs rejects empty fstype (should have returned non-zero)"
fi

# Restore findmnt
unset -f findmnt

report
