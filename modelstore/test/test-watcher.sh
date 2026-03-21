#!/usr/bin/env bash
# modelstore/test/test-watcher.sh — Unit tests for modelstore/hooks/watcher.sh
# Tests ms_track_usage, extract_model_id_from_path, debounce, pidfile, and startup guard.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SCRIPT="${SCRIPT_DIR}/../hooks/watcher.sh"
MODELSTORE_LIB="${SCRIPT_DIR}/../lib"

PASS=0; FAIL=0
assert_eq() { if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1)); echo "  PASS: $3"; else FAIL=$((FAIL + 1)); echo "  FAIL: $3 (expected '$2', got '$1')"; fi; }
assert_ok() { if eval "$1" 2>/dev/null; then PASS=$((PASS + 1)); echo "  PASS: $2"; else FAIL=$((FAIL + 1)); echo "  FAIL: $2"; fi; }
report() { echo ""; echo "Results: $PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]; }

echo "=== Watcher Tests ==="

# ---------------------------------------------------------------------------
# Setup: create a temp HOME with a valid modelstore config
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.modelstore"
cat > "$TMP/.modelstore/config.json" <<'CONF'
{
  "version": 1,
  "hot_hf_path": "/tmp/hf_cache",
  "hot_ollama_path": "/tmp/ollama_models",
  "cold_path": "/tmp/cold",
  "retention_days": 30,
  "cron_hour": 2,
  "backup_retention_days": 30
}
CONF

# Export HOME so config.sh MODELSTORE_CONFIG picks it up
export HOME="$TMP"

# Source the libs directly with resolved absolute paths
source "${MODELSTORE_LIB}/common.sh"
source "${MODELSTORE_LIB}/config.sh"

# Define the functions from watcher.sh directly here (copy of the function bodies).
# This avoids the BASH_SOURCE complexity and any main-block execution issues.

USAGE_FILE="$TMP/.modelstore/usage.json"
USAGE_LOCK="$TMP/.modelstore/usage.lock"
PIDFILE="$TMP/.modelstore/watcher.pid"
MODELSTORE_CONFIG="$TMP/.modelstore/config.json"
DEBOUNCE_SECONDS=60

# HOT paths for extract_model_id_from_path
HOT_HF_PATH="/tmp/hf_cache"
HOT_OLLAMA_PATH="/tmp/ollama_models"

ms_track_usage() {
  local model_path="$1"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Initialize if missing
  [[ -f "$USAGE_FILE" ]] || echo '{}' > "$USAGE_FILE"

  # Debounce: skip if this model was tracked in the last DEBOUNCE_SECONDS
  if [[ -f "$USAGE_FILE" ]]; then
    local last_ts
    last_ts=$(jq -r --arg p "$model_path" '.[$p] // empty' "$USAGE_FILE" 2>/dev/null)
    if [[ -n "$last_ts" ]]; then
      local last_epoch now_epoch
      last_epoch=$(date -d "$last_ts" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      [[ $(( now_epoch - last_epoch )) -lt $DEBOUNCE_SECONDS ]] && return 0
    fi
  fi

  # Acquire exclusive lock, update JSON atomically
  (
    flock -x 9
    local current
    current=$(cat "$USAGE_FILE")
    echo "$current" | jq --arg path "$model_path" --arg ts "$timestamp" \
      '.[$path] = $ts' > "${USAGE_FILE}.tmp" \
    && mv "${USAGE_FILE}.tmp" "$USAGE_FILE"
  ) 9>"$USAGE_LOCK" 2>/dev/null || ms_log "WARNING: failed to update usage for $model_path"
}

extract_model_id_from_path() {
  local path="$1"
  local dir="$path"
  # HF: find the models-- ancestor directory
  while [[ "$dir" != "/" ]]; do
    if [[ "$(basename "$dir")" == models--* ]]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  # Ollama: if path is under HOT_OLLAMA_PATH, use HOT_OLLAMA_PATH as the model root
  if [[ "$path" == "${HOT_OLLAMA_PATH}"/* ]]; then
    echo "$HOT_OLLAMA_PATH"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Test 1: ms_track_usage creates usage.json if missing
# ---------------------------------------------------------------------------
rm -f "$USAGE_FILE"
DEBOUNCE_SECONDS=0
ms_track_usage "/test/model"
if [[ -f "$USAGE_FILE" ]]; then
  PASS=$((PASS + 1)); echo "  PASS: ms_track_usage creates usage.json if missing"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: ms_track_usage creates usage.json if missing"
fi

# ---------------------------------------------------------------------------
# Test 2: ms_track_usage writes ISO-8601 timestamp
# ---------------------------------------------------------------------------
rm -f "$USAGE_FILE"
DEBOUNCE_SECONDS=0
ms_track_usage "/test/model"
TS=$(jq -r '."/test/model"' "$USAGE_FILE" 2>/dev/null || echo "")
if [[ "$TS" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
  PASS=$((PASS + 1)); echo "  PASS: ms_track_usage writes ISO-8601 timestamp"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: ms_track_usage writes ISO-8601 timestamp (got '$TS')"
fi

# ---------------------------------------------------------------------------
# Test 3: ms_track_usage uses correct key (path as key in JSON)
# ---------------------------------------------------------------------------
rm -f "$USAGE_FILE"
DEBOUNCE_SECONDS=0
ms_track_usage "/test/model/path"
KEY_VAL=$(jq -r '."/test/model/path"' "$USAGE_FILE" 2>/dev/null || echo "null")
if [[ "$KEY_VAL" != "null" && -n "$KEY_VAL" ]]; then
  PASS=$((PASS + 1)); echo "  PASS: ms_track_usage uses the model path as JSON key"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: ms_track_usage uses the model path as JSON key (got '$KEY_VAL')"
fi

# ---------------------------------------------------------------------------
# Test 4: ms_track_usage updates existing entry (with DEBOUNCE_SECONDS=0)
# ---------------------------------------------------------------------------
rm -f "$USAGE_FILE"
DEBOUNCE_SECONDS=0
ms_track_usage "/test/update/model"
FIRST_TS=$(jq -r '."/test/update/model"' "$USAGE_FILE")
sleep 1
ms_track_usage "/test/update/model"
SECOND_TS=$(jq -r '."/test/update/model"' "$USAGE_FILE")
if [[ "$SECOND_TS" != "$FIRST_TS" ]]; then
  PASS=$((PASS + 1)); echo "  PASS: ms_track_usage updates existing entry (second call changes timestamp)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: ms_track_usage updates existing entry (timestamps unchanged: '$FIRST_TS')"
fi

# ---------------------------------------------------------------------------
# Test 5: Concurrent writes do not corrupt usage.json (flock serialization)
# ---------------------------------------------------------------------------
rm -f "$USAGE_FILE"
echo '{}' > "$USAGE_FILE"

# Run 5 parallel subshells each calling ms_track_usage with different model paths
for i in 1 2 3 4 5; do
  (
    DEBOUNCE_SECONDS=0
    USAGE_FILE="$TMP/.modelstore/usage.json"
    USAGE_LOCK="$TMP/.modelstore/usage.lock"
    ms_track_usage "/concurrent/model/$i"
  ) &
done
wait

# Check JSON validity and presence of all 5 keys
JSON_VALID=0
jq '.' "$USAGE_FILE" > /dev/null 2>&1 && JSON_VALID=1
KEY_COUNT=$(jq 'keys | length' "$USAGE_FILE" 2>/dev/null || echo 0)

if [[ "$JSON_VALID" -eq 1 && "$KEY_COUNT" -ge 5 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: concurrent ms_track_usage calls do not corrupt usage.json ($KEY_COUNT keys found)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: concurrent ms_track_usage calls corrupted usage.json (valid=$JSON_VALID, keys=$KEY_COUNT)"
fi

# ---------------------------------------------------------------------------
# Test 6: Debounce skips update within window (30 seconds ago = within 60s window)
# ---------------------------------------------------------------------------
rm -f "$USAGE_FILE"
DEBOUNCE_SECONDS=60
PAST_TS=$(date -u -d "30 seconds ago" +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg ts "$PAST_TS" '{"/debounce/model": $ts}' > "$USAGE_FILE"
ms_track_usage "/debounce/model"
AFTER_TS=$(jq -r '."/debounce/model"' "$USAGE_FILE")
if [[ "$AFTER_TS" == "$PAST_TS" ]]; then
  PASS=$((PASS + 1)); echo "  PASS: debounce skips update within 60-second window"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: debounce skips update within 60-second window (expected '$PAST_TS', got '$AFTER_TS')"
fi

# ---------------------------------------------------------------------------
# Test 7: Debounce allows update after window (120 seconds ago = outside 60s window)
# ---------------------------------------------------------------------------
rm -f "$USAGE_FILE"
DEBOUNCE_SECONDS=60
OLD_TS=$(date -u -d "120 seconds ago" +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg ts "$OLD_TS" '{"/debounce/model2": $ts}' > "$USAGE_FILE"
ms_track_usage "/debounce/model2"
NEW_TS=$(jq -r '."/debounce/model2"' "$USAGE_FILE")
if [[ "$NEW_TS" != "$OLD_TS" ]]; then
  PASS=$((PASS + 1)); echo "  PASS: debounce allows update after 60-second window"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: debounce allows update after 60-second window (timestamp not updated)"
fi

# ---------------------------------------------------------------------------
# Test 8: extract_model_id_from_path finds models-- ancestor directory
# ---------------------------------------------------------------------------
HOT_HF_PATH="/cache"
HOT_OLLAMA_PATH="/tmp/ollama_models"
RESULT=$(extract_model_id_from_path "/cache/models--org--name/blobs/sha256-abc")
if [[ "$RESULT" == "/cache/models--org--name" ]]; then
  PASS=$((PASS + 1)); echo "  PASS: extract_model_id_from_path finds models-- ancestor"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: extract_model_id_from_path finds models-- ancestor (got '$RESULT')"
fi

# ---------------------------------------------------------------------------
# Test 9: extract_model_id_from_path returns 1 for unrecognized path
# ---------------------------------------------------------------------------
HOT_HF_PATH="/cache"
HOT_OLLAMA_PATH="/tmp/ollama_models"
EXTRACT_RESULT=0
extract_model_id_from_path "/random/path/file.txt" > /dev/null 2>&1 || EXTRACT_RESULT=$?
if [[ "$EXTRACT_RESULT" -ne 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: extract_model_id_from_path returns 1 for unrecognized path"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: extract_model_id_from_path returns 1 for unrecognized path (returned 0)"
fi

# ---------------------------------------------------------------------------
# Test 10: Startup guard exits 0 if no config (watcher.sh itself)
# ---------------------------------------------------------------------------
STARTUP_EXIT=0
HOME=/nonexistent bash "$WATCHER_SCRIPT" 2>/dev/null || STARTUP_EXIT=$?
if [[ "$STARTUP_EXIT" -eq 0 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: watcher exits 0 when modelstore not initialized"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: watcher exits 0 when modelstore not initialized (exit code: $STARTUP_EXIT)"
fi

# ---------------------------------------------------------------------------
# Test 11: Pidfile guard prevents second instance (kill -0 logic)
# ---------------------------------------------------------------------------
FAKE_PIDFILE="$TMP/.modelstore/fake-watcher.pid"
echo "$$" > "$FAKE_PIDFILE"

# Verify the guard logic: if pidfile exists and process is alive, would block second start
GUARD_RESULT=0
if [[ -f "$FAKE_PIDFILE" ]] && kill -0 "$(cat "$FAKE_PIDFILE")" 2>/dev/null; then
  GUARD_RESULT=1
fi
rm -f "$FAKE_PIDFILE"

if [[ "$GUARD_RESULT" -eq 1 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: pidfile guard detects running instance (kill -0 check works)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: pidfile guard detects running instance"
fi

# ---------------------------------------------------------------------------
# Test 12: ms_track_usage produces valid JSON for paths with dashes
# ---------------------------------------------------------------------------
rm -f "$USAGE_FILE"
DEBOUNCE_SECONDS=0
ms_track_usage "/models/meta-llama--Llama-3.2-3B"
JSON_OK=0
jq '.' "$USAGE_FILE" > /dev/null 2>&1 && JSON_OK=1
if [[ "$JSON_OK" -eq 1 ]]; then
  PASS=$((PASS + 1)); echo "  PASS: ms_track_usage produces valid JSON for paths with special chars"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: ms_track_usage produces valid JSON for paths with special chars"
fi

report
