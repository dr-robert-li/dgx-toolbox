#!/usr/bin/env bash
# modelstore/test/test-migrate.sh — Tests for cmd/migrate.sh, lib/ollama_adapter.sh
# Covers: MIGR-01 through MIGR-07, SAFE-05
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELSTORE_LIB="${SCRIPT_DIR}/../lib"
MODELSTORE_CMD="${SCRIPT_DIR}/../cmd"
MODELSTORE_CRON="${SCRIPT_DIR}/../cron"

PASS=0; FAIL=0
assert_eq() { if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1)); echo "  PASS: $3"; else FAIL=$((FAIL + 1)); echo "  FAIL: $3 (expected '$2', got '$1')"; fi; }
assert_ok() { if eval "$1" 2>/dev/null; then PASS=$((PASS + 1)); echo "  PASS: $2"; else FAIL=$((FAIL + 1)); echo "  FAIL: $2"; fi; }
report() { echo ""; echo "Results: $PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]; }

echo "=== Migrate Tests ==="

# ---------------------------------------------------------------------------
# Setup: temp environment
# ---------------------------------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.modelstore"
mkdir -p "$TMP/hf_cache"
mkdir -p "$TMP/cold_mount"
mkdir -p "$TMP/ollama_models/models/manifests/registry.ollama.ai/library"
mkdir -p "$TMP/ollama_models/models/blobs"

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

# ---------------------------------------------------------------------------
# Source libs and load functions from migrate.sh inline to avoid exec
# ---------------------------------------------------------------------------
source "${MODELSTORE_LIB}/common.sh"
source "${MODELSTORE_LIB}/config.sh"
source "${MODELSTORE_LIB}/hf_adapter.sh"
source "${MODELSTORE_LIB}/ollama_adapter.sh"
source "${MODELSTORE_LIB}/audit.sh"

load_config

USAGE_FILE="${HOME}/.modelstore/usage.json"
OP_STATE_FILE="${HOME}/.modelstore/op_state.json"
AUDIT_LOG="${HOME}/.modelstore/audit.log"

# Inline the state helpers and stale detection functions (avoids sourcing the full migrate.sh)
_write_op_state() {
  local op="$1" model="$2" phase="$3" trigger="$4"
  jq -cn \
    --arg op "$op" --arg m "$model" --arg ph "$phase" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg tr "$trigger" \
    '{op:$op, model:$m, phase:$ph, started_at:$ts, trigger:$tr}' \
    > "${OP_STATE_FILE}.tmp"
  mv "${OP_STATE_FILE}.tmp" "$OP_STATE_FILE"
}
_clear_op_state() { rm -f "$OP_STATE_FILE"; }

find_stale_hf_models() {
  local cutoff_epoch
  cutoff_epoch=$(date -d "${RETENTION_DAYS} days ago" +%s)
  if [[ -f "$USAGE_FILE" ]]; then
    jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$USAGE_FILE" 2>/dev/null \
    | while IFS=$'\t' read -r model_path last_used; do
        [[ "$model_path" != "${HOT_HF_PATH}/models--"* ]] && continue
        [[ -L "$model_path" ]] && continue
        local last_epoch
        last_epoch=$(date -d "$last_used" +%s 2>/dev/null || echo 0)
        [[ "$last_epoch" -lt "$cutoff_epoch" ]] && echo "$model_path"
      done
  fi
  for model_dir in "${HOT_HF_PATH}"/models--*/; do
    [[ -d "$model_dir" ]] || continue
    local key="${model_dir%/}"
    [[ -L "$key" ]] && continue
    if ! jq -e --arg k "$key" 'has($k)' "$USAGE_FILE" &>/dev/null 2>&1; then
      echo "$key"
    fi
  done
}

# Mock: override check_cold_mounted to no-op (cold mount always passes in tests)
check_cold_mounted() { return 0; }

# Mock: override check_space to always pass
check_space() { return 0; }

# ---------------------------------------------------------------------------
# Test 1: MIGR-01 — No stale models detected when all models used within retention
# ---------------------------------------------------------------------------
echo ""
echo "--- Test MIGR-01: cron_no_stale ---"

# Create fresh model dir
mkdir -p "$TMP/hf_cache/models--org--fresh/blobs"
echo "data" > "$TMP/hf_cache/models--org--fresh/blobs/sha256-abc"

# Set usage.json with a recent timestamp (1 day ago)
recent_ts=$(date -d "1 day ago" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -v-1d -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2026-03-20T12:00:00Z")
jq -n --arg k "${TMP}/hf_cache/models--org--fresh" --arg ts "$recent_ts" '{($k): $ts}' > "$USAGE_FILE"

stale_output=$(find_stale_hf_models 2>/dev/null || true)
if [[ -z "$stale_output" ]]; then
  PASS=$((PASS + 1)); echo "  PASS: no stale models when all used within retention (MIGR-01)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: expected no stale models, got: $stale_output"
fi

# Cleanup
rm -rf "$TMP/hf_cache/models--org--fresh"
rm -f "$USAGE_FILE"

# ---------------------------------------------------------------------------
# Test 2: MIGR-02 — Migrated HF model path becomes a symlink
# ---------------------------------------------------------------------------
echo ""
echo "--- Test MIGR-02: symlink_created ---"

mkdir -p "$TMP/hf_cache/models--org--migratetest/blobs"
echo "data" > "$TMP/hf_cache/models--org--migratetest/blobs/sha256-xyz"

# Mock rsync to simulate file move
rsync() {
  local args=() src="" dst=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--remove-source-files) shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  src="${args[0]%/}"; dst="${args[1]%/}"
  mkdir -p "$dst"
  [[ -d "$src" ]] && find "$src" -type f -exec mv {} "$dst/" \; 2>/dev/null || true
}

hf_migrate_model "$TMP/hf_cache/models--org--migratetest" "$TMP/cold_mount" 2>/dev/null
unset -f rsync

if [[ -L "$TMP/hf_cache/models--org--migratetest" ]]; then
  PASS=$((PASS + 1)); echo "  PASS: migrated model path is now a symlink (MIGR-02)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: expected symlink at model path after migration"
fi

# Cleanup
rm -f "$TMP/hf_cache/models--org--migratetest"
rm -rf "$TMP/cold_mount/hf"

# ---------------------------------------------------------------------------
# Test 3: MIGR-03 — Atomic symlink swap (no .new intermediate file left)
# ---------------------------------------------------------------------------
echo ""
echo "--- Test MIGR-03: atomic_swap ---"

mkdir -p "$TMP/hf_cache/models--org--atomictest/blobs"
echo "data" > "$TMP/hf_cache/models--org--atomictest/blobs/sha256-def"

rsync() {
  local args=() src="" dst=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--remove-source-files) shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  src="${args[0]%/}"; dst="${args[1]%/}"
  mkdir -p "$dst"
  [[ -d "$src" ]] && find "$src" -type f -exec mv {} "$dst/" \; 2>/dev/null || true
}

hf_migrate_model "$TMP/hf_cache/models--org--atomictest" "$TMP/cold_mount" 2>/dev/null
unset -f rsync

# .new file must not exist after migration
new_file_exists=0
[[ -e "$TMP/hf_cache/models--org--atomictest.new" ]] && new_file_exists=1

assert_eq "$new_file_exists" "0" "no .new intermediate file after atomic symlink swap (MIGR-03)"
assert_ok "[[ -L '$TMP/hf_cache/models--org--atomictest' ]]" "final path is a symlink after atomic swap (MIGR-03)"

# Cleanup
rm -f "$TMP/hf_cache/models--org--atomictest"
rm -rf "$TMP/cold_mount/hf"

# ---------------------------------------------------------------------------
# Test 4: MIGR-04 — HF model directory structure preserved in cold storage
# ---------------------------------------------------------------------------
echo ""
echo "--- Test MIGR-04: hf_whole_dir ---"

mkdir -p "$TMP/hf_cache/models--org--structtest/snapshots/abc123/pytorch"
mkdir -p "$TMP/hf_cache/models--org--structtest/blobs"
echo "weight data" > "$TMP/hf_cache/models--org--structtest/snapshots/abc123/pytorch/model.bin"
echo "blob data" > "$TMP/hf_cache/models--org--structtest/blobs/sha256-ghi"

rsync() {
  local args=() src="" dst=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--remove-source-files) shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  src="${args[0]%/}"; dst="${args[1]%/}"
  mkdir -p "$dst"
  # Use real cp -r to preserve structure
  cp -r "$src/." "$dst/" 2>/dev/null || true
  # Remove source files to simulate --remove-source-files
  find "$src" -type f -delete 2>/dev/null || true
}

hf_migrate_model "$TMP/hf_cache/models--org--structtest" "$TMP/cold_mount" 2>/dev/null
unset -f rsync

cold_target="$TMP/cold_mount/hf/models--org--structtest"
dir_ok=0
[[ -d "${cold_target}/blobs" ]] && [[ -d "${cold_target}/snapshots" ]] && dir_ok=1
assert_eq "$dir_ok" "1" "cold storage has full directory structure (MIGR-04)"

# Cleanup
rm -f "$TMP/hf_cache/models--org--structtest"
rm -rf "$TMP/cold_mount/hf"

# ---------------------------------------------------------------------------
# Test 5: MIGR-05 — Ollama blob reference counting (shared blob stays on hot)
# ---------------------------------------------------------------------------
echo ""
echo "--- Test MIGR-05: ollama_blob_refcount ---"

# Create two Ollama models sharing a common blob
shared_blob="sha256-sharedblob000111"
model_a_only_blob="sha256-modela000111222"
model_b_only_blob="sha256-modelb000111222"

# Create blob files on hot
echo "shared content" > "$TMP/ollama_models/models/blobs/${shared_blob}"
echo "model a content" > "$TMP/ollama_models/models/blobs/${model_a_only_blob}"
echo "model b content" > "$TMP/ollama_models/models/blobs/${model_b_only_blob}"

# Create manifests for model_a and model_b
mkdir -p "$TMP/ollama_models/models/manifests/registry.ollama.ai/library/model_a"
mkdir -p "$TMP/ollama_models/models/manifests/registry.ollama.ai/library/model_b"

cat > "$TMP/ollama_models/models/manifests/registry.ollama.ai/library/model_a/latest" <<MANIF_A
{
  "layers": [{"digest": "sha256:${model_a_only_blob#sha256-}"}],
  "config": {"digest": "sha256:${shared_blob#sha256-}"}
}
MANIF_A

cat > "$TMP/ollama_models/models/manifests/registry.ollama.ai/library/model_b/latest" <<MANIF_B
{
  "layers": [{"digest": "sha256:${model_b_only_blob#sha256-}"}],
  "config": {"digest": "sha256:${shared_blob#sha256-}"}
}
MANIF_B

# Mock ollama_check_server to return 1 (stopped) for migration
ollama_check_server() { return 1; }

# Mock ollama_get_model_size to return 0
ollama_get_model_size() { echo 0; }

# Migrate model_a — shared blob should remain as regular file (ref count = 2, still referenced by model_b)
ollama_migrate_model "model_a" "$TMP/cold_mount" 2>/dev/null || true

shared_is_regular=0
# After migrating model_a, shared blob should still be a regular file (ref count > 1)
if [[ -f "$TMP/ollama_models/models/blobs/${shared_blob}" && ! -L "$TMP/ollama_models/models/blobs/${shared_blob}" ]]; then
  shared_is_regular=1
fi
assert_eq "$shared_is_regular" "1" "shared blob stays as regular file when referenced by 2 models (MIGR-05)"

# model_a's private blob should now be a symlink (ref count = 1, only model_a referenced it)
modela_is_symlink=0
[[ -L "$TMP/ollama_models/models/blobs/${model_a_only_blob}" ]] && modela_is_symlink=1
assert_eq "$modela_is_symlink" "1" "model_a exclusive blob is symlink after migration (MIGR-05)"

unset -f ollama_check_server ollama_get_model_size

# Cleanup
rm -rf "$TMP/cold_mount/ollama"
rm -f "$TMP/ollama_models/models/blobs/${shared_blob}"
rm -f "$TMP/ollama_models/models/blobs/${model_a_only_blob}"
rm -f "$TMP/ollama_models/models/blobs/${model_b_only_blob}"

# ---------------------------------------------------------------------------
# Test 6: MIGR-06 — Concurrent invocation of migrate_cron.sh exits immediately
# ---------------------------------------------------------------------------
echo ""
echo "--- Test MIGR-06: flock_skip ---"

LOCK_FILE="$TMP/.modelstore/migrate.lock"

# Acquire the lock ourselves (simulating a running migration)
exec 9>"$LOCK_FILE"
flock -x 9

# Run migrate_cron.sh — it should exit 0 with "already running" message
# Capture output to a temp file (background process substitution with set -u is tricky)
cron_out_file="$TMP/cron_output.txt"
"${MODELSTORE_CRON}/migrate_cron.sh" 2>&1 | tee "$cron_out_file" || true

# Release our lock
exec 9>&-

cron_output=""
[[ -f "$cron_out_file" ]] && cron_output=$(cat "$cron_out_file")

already_msg=0
[[ "$cron_output" == *"already running"* ]] && already_msg=1
assert_eq "$already_msg" "1" "migrate_cron.sh exits with 'already running' message when lock held (MIGR-06)"

# ---------------------------------------------------------------------------
# Test 7: MIGR-07 — Dry-run prints table and makes no filesystem changes
# ---------------------------------------------------------------------------
echo ""
echo "--- Test MIGR-07: dry_run ---"

# Create a stale model (timestamp 90 days ago, beyond 14-day retention)
mkdir -p "$TMP/hf_cache/models--org--staletest/blobs"
echo "data" > "$TMP/hf_cache/models--org--staletest/blobs/sha256-stale"

stale_ts=$(date -d "90 days ago" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2025-12-21T00:00:00Z")
jq -n --arg k "${TMP}/hf_cache/models--org--staletest" --arg ts "$stale_ts" '{($k): $ts}' > "$USAGE_FILE"

# Run --dry-run and capture output
dry_output=$(HOME="$TMP" "${MODELSTORE_CMD}/migrate.sh" --dry-run 2>&1 || true)

# Check output contains "Would migrate"
would_migrate=0
[[ "$dry_output" == *"Would migrate"* ]] && would_migrate=1
assert_eq "$would_migrate" "1" "dry-run output contains 'Would migrate' section (MIGR-07)"

# Check filesystem was NOT changed — model dir is still a directory, not a symlink
still_dir=0
[[ -d "$TMP/hf_cache/models--org--staletest" && ! -L "$TMP/hf_cache/models--org--staletest" ]] && still_dir=1
assert_eq "$still_dir" "1" "dry-run does not modify the filesystem (MIGR-07)"

# Cleanup
rm -rf "$TMP/hf_cache/models--org--staletest"
rm -f "$USAGE_FILE"

# ---------------------------------------------------------------------------
# Test 8: SAFE-05 — Stale op_state.json (>4 hours old) is cleared on startup
# ---------------------------------------------------------------------------
echo ""
echo "--- Test SAFE-05: state_resume ---"

# Create an op_state.json with started_at 5 hours ago
stale_op_ts=$(date -d "5 hours ago" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2026-03-21T07:00:00Z")
jq -n --arg ts "$stale_op_ts" '{op:"migrate",model:"/test",phase:"rsync",started_at:$ts,trigger:"cron"}' > "$OP_STATE_FILE"

# Write a usage.json with no stale models so migrate.sh runs quickly without actually doing anything
jq -n '{}' > "$USAGE_FILE"

# Run migrate.sh (real mode) — it should detect stale state file and clear it
state_output=$(HOME="$TMP" "${MODELSTORE_CMD}/migrate.sh" 2>&1 || true)

# Check log message about clearing stale state
cleared_msg=0
[[ "$state_output" == *"Clearing stale operation state"* ]] && cleared_msg=1
assert_eq "$cleared_msg" "1" "stale op_state.json (>4h old) cleared at startup (SAFE-05)"

# Check op_state.json was deleted
op_deleted=0
[[ ! -f "$OP_STATE_FILE" ]] && op_deleted=1
assert_eq "$op_deleted" "1" "op_state.json deleted after stale state cleared (SAFE-05)"

# Cleanup
rm -f "$USAGE_FILE"

# ---------------------------------------------------------------------------
report
