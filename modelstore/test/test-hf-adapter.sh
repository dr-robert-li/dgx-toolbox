#!/usr/bin/env bash
# modelstore/test/test-hf-adapter.sh — Unit tests for lib/hf_adapter.sh
# Tests: list, size, path, migrate (guards + success), recall (guards + success)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELSTORE_LIB="${SCRIPT_DIR}/../lib"

PASS=0; FAIL=0
assert_eq() { if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1)); echo "  PASS: $3"; else FAIL=$((FAIL + 1)); echo "  FAIL: $3 (expected '$2', got '$1')"; fi; }
assert_ok() { if eval "$1" 2>/dev/null; then PASS=$((PASS + 1)); echo "  PASS: $2"; else FAIL=$((FAIL + 1)); echo "  FAIL: $2"; fi; }
report() { echo ""; echo "Results: $PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]; }

echo "=== HF Adapter Tests ==="

# ---------------------------------------------------------------------------
# Setup: temp environment
# ---------------------------------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Create fake HOME with config
mkdir -p "$TMP/.modelstore"
mkdir -p "$TMP/hf_cache"
mkdir -p "$TMP/cold_mount"

# Create mock model directory with a small test file
mkdir -p "$TMP/hf_cache/models--org--testmodel/blobs"
echo "fake model data" > "$TMP/hf_cache/models--org--testmodel/blobs/sha256-abcd1234"

# Write fake config (hot_hf_path points to TMP/hf_cache)
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

# Override HOME so load_config reads fake config
export HOME="$TMP"

# Source the adapter chain
# shellcheck source=../lib/common.sh
source "${MODELSTORE_LIB}/common.sh"
# shellcheck source=../lib/config.sh
source "${MODELSTORE_LIB}/config.sh"
# shellcheck source=../lib/hf_adapter.sh
source "${MODELSTORE_LIB}/hf_adapter.sh"

MODEL_DIR="$TMP/hf_cache/models--org--testmodel"
COLD_BASE="$TMP/cold_mount"

# ---------------------------------------------------------------------------
# Test 1: hf_get_model_size returns a positive integer
# ---------------------------------------------------------------------------
SIZE_OUTPUT=$(hf_get_model_size "$MODEL_DIR" 2>/dev/null)
SIZE_IS_INT=0
[[ "$SIZE_OUTPUT" =~ ^[0-9]+$ ]] && SIZE_IS_INT=1
assert_eq "$SIZE_IS_INT" "1" "hf_get_model_size returns a positive integer"

# ---------------------------------------------------------------------------
# Test 2: hf_get_model_path returns the model_id unchanged
# ---------------------------------------------------------------------------
PATH_OUTPUT=$(hf_get_model_path "$MODEL_DIR" 2>/dev/null)
assert_eq "$PATH_OUTPUT" "$MODEL_DIR" "hf_get_model_path returns model_id unchanged"

# ---------------------------------------------------------------------------
# Test 3: hf_list_models fallback finds test model directory (force python3 to fail)
# ---------------------------------------------------------------------------
python3() { return 1; }
LIST_OUTPUT=$(hf_list_models 2>/dev/null)
LIST_CONTAINS_MODEL=0
[[ "$LIST_OUTPUT" == *"models--org--testmodel"* ]] && LIST_CONTAINS_MODEL=1
assert_eq "$LIST_CONTAINS_MODEL" "1" "hf_list_models fallback finds test model"
unset -f python3

# ---------------------------------------------------------------------------
# Test 4: hf_list_models fallback output is TSV with path<TAB>size
# ---------------------------------------------------------------------------
python3() { return 1; }
LIST_TSV=$(hf_list_models 2>/dev/null | head -1)
TSV_HAS_TAB=0
[[ "$LIST_TSV" == *$'\t'* ]] && TSV_HAS_TAB=1
assert_eq "$TSV_HAS_TAB" "1" "hf_list_models fallback output is TAB-separated"
unset -f python3

# ---------------------------------------------------------------------------
# Test 5: hf_migrate_model calls check_cold_mounted — aborts if cold not mounted (SAFE-01)
# Override mountpoint to return 1 (failure)
# ---------------------------------------------------------------------------
mountpoint() { return 1; }
MOUNT_FAIL_EXIT=0
(hf_migrate_model "$MODEL_DIR" "$COLD_BASE" 2>/dev/null) || MOUNT_FAIL_EXIT=$?
unset -f mountpoint
if [[ "$MOUNT_FAIL_EXIT" -ne 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: hf_migrate_model exits non-zero when cold not mounted (SAFE-01)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: hf_migrate_model should exit non-zero when cold not mounted"
fi

# ---------------------------------------------------------------------------
# Test 6: hf_migrate_model calls check_space — returns 1 if insufficient space (SAFE-02)
# Override mountpoint to pass, df to return tiny space, du to return large size
# (model size must exceed available space for the check to fail)
# ---------------------------------------------------------------------------
mountpoint() { return 0; }
df() { echo "100"; }        # 100 bytes available -> 90 usable
du() { echo "999999999"; }  # mock model as 1GB so it exceeds available 90 bytes
SPACE_RESULT=0
hf_migrate_model "$MODEL_DIR" "$COLD_BASE" 2>/dev/null || SPACE_RESULT=$?
unset -f mountpoint df du
if [[ "$SPACE_RESULT" -ne 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: hf_migrate_model returns non-zero on insufficient space (SAFE-02)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: hf_migrate_model should return non-zero on insufficient space"
fi

# ---------------------------------------------------------------------------
# Test 7: hf_migrate_model skips if already a symlink ("Already migrated")
# Create a dangling symlink to simulate an already-migrated model
# ---------------------------------------------------------------------------
SYMLINK_MODEL="$TMP/hf_cache/models--org--alreadymigrated"
ln -s "$TMP/cold_mount/hf/models--org--alreadymigrated" "$SYMLINK_MODEL"
ALREADY_LOG=$(hf_migrate_model "$SYMLINK_MODEL" "$COLD_BASE" 2>&1)
ALREADY_RESULT=$?
ALREADY_CONTAINS=0
[[ "$ALREADY_LOG" == *"Already migrated"* ]] && ALREADY_CONTAINS=1
assert_eq "$ALREADY_RESULT" "0" "hf_migrate_model returns 0 when already a symlink"
assert_eq "$ALREADY_CONTAINS" "1" "hf_migrate_model logs 'Already migrated' for symlinks"
rm -f "$SYMLINK_MODEL"

# ---------------------------------------------------------------------------
# Test 8: hf_migrate_model creates symlink on success
# Create a separate model dir, mock mountpoint/df to succeed, mock rsync to copy files
# ---------------------------------------------------------------------------
MIGRATE_MODEL="$TMP/hf_cache/models--org--migratetest"
mkdir -p "$MIGRATE_MODEL/blobs"
echo "fake" > "$MIGRATE_MODEL/blobs/testfile"
mountpoint() { return 0; }
df() { echo "107374182400"; }  # 100 GiB available
rsync() {
  # Simulate rsync --remove-source-files: move files from src/ to dst/
  local src="" dst=""
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--remove-source-files) shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  src="${args[0]%/}"
  dst="${args[1]%/}"
  mkdir -p "$dst"
  # Move all files (removing from source, simulating --remove-source-files)
  [[ -d "$src" ]] && find "$src" -type f -exec mv {} "$dst/" \; 2>/dev/null || true
}
MIGRATE_RESULT=0
hf_migrate_model "$MIGRATE_MODEL" "$COLD_BASE" 2>/dev/null || MIGRATE_RESULT=$?
unset -f mountpoint df rsync
if [[ -L "$MIGRATE_MODEL" ]]; then
  PASS=$((PASS + 1)); echo "  PASS: hf_migrate_model creates symlink at model_id on success"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: hf_migrate_model should create symlink (got: $(ls -la "$MIGRATE_MODEL" 2>&1 || echo 'missing'))"
fi
# Cleanup symlink for subsequent tests
rm -f "$MIGRATE_MODEL" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 9: hf_recall_model skips if not a symlink (returns 0 + logs "Not a symlink")
# ---------------------------------------------------------------------------
RECALL_LOG=$(hf_recall_model "$MODEL_DIR" "$TMP/hf_cache" 2>&1)
RECALL_RESULT=$?
RECALL_CONTAINS=0
[[ "$RECALL_LOG" == *"Not a symlink"* ]] && RECALL_CONTAINS=1
assert_eq "$RECALL_RESULT" "0" "hf_recall_model returns 0 for non-symlink path"
assert_eq "$RECALL_CONTAINS" "1" "hf_recall_model logs 'Not a symlink, skip recall'"

# ---------------------------------------------------------------------------
# Test 10: hf_get_model_size returns size greater than 0
# ---------------------------------------------------------------------------
actual_size=$(hf_get_model_size "$MODEL_DIR" 2>/dev/null)
SIZE_GT_ZERO=0
[[ -n "$actual_size" ]] && [[ "$actual_size" -gt 0 ]] && SIZE_GT_ZERO=1
assert_eq "$SIZE_GT_ZERO" "1" "hf_get_model_size returns size > 0 for non-empty model"

# ---------------------------------------------------------------------------
report
