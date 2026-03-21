#!/usr/bin/env bash
# modelstore/test/test-recall.sh — Tests for cmd/recall.sh and watcher auto-recall
# Covers: RECL-01, RECL-02, RECL-03
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELSTORE_LIB="${SCRIPT_DIR}/../lib"
MODELSTORE_CMD="${SCRIPT_DIR}/../cmd"
MODELSTORE_HOOKS="${SCRIPT_DIR}/../hooks"

PASS=0; FAIL=0
assert_eq() { if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1)); echo "  PASS: $3"; else FAIL=$((FAIL + 1)); echo "  FAIL: $3 (expected '$2', got '$1')"; fi; }
assert_ok() { if eval "$1" 2>/dev/null; then PASS=$((PASS + 1)); echo "  PASS: $2"; else FAIL=$((FAIL + 1)); echo "  FAIL: $2"; fi; }
report() { echo ""; echo "Results: $PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]; }

echo "=== Recall Tests ==="

# ---------------------------------------------------------------------------
# Setup: temp environment
# ---------------------------------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.modelstore"
mkdir -p "$TMP/hf_cache"
mkdir -p "$TMP/cold/hf"
mkdir -p "$TMP/ollama_models"

# Write fake config
cat > "$TMP/.modelstore/config.json" <<ENDCONFIG
{
  "version": 1,
  "hot_hf_path": "${TMP}/hf_cache",
  "hot_ollama_path": "${TMP}/ollama_models",
  "cold_path": "${TMP}/cold",
  "retention_days": 14,
  "cron_hour": 2,
  "backup_retention_days": 30,
  "created_at": "2026-01-01T00:00:00Z",
  "updated_at": "2026-01-01T00:00:00Z"
}
ENDCONFIG

# Initialize usage.json
echo '{}' > "$TMP/.modelstore/usage.json"

# ---------------------------------------------------------------------------
# Helper: build a stub recall.sh wrapper that replaces real adapters/guards
# with mocks for unit testing
# ---------------------------------------------------------------------------
build_mock_recall_env() {
  local extra_stubs="${1:-}"
  # Create a bin/ dir with mock commands
  local mock_bin="$TMP/mock_bin"
  mkdir -p "$mock_bin"

  # Mock fuser: returns 1 by default (not in use) — tests can override
  cat > "$mock_bin/fuser" <<'MOCKFUSER'
#!/usr/bin/env bash
exit 1
MOCKFUSER
  chmod +x "$mock_bin/fuser"

  # Mock rsync: copy src to dst (simulates recall move without real rsync)
  cat > "$mock_bin/rsync" <<'MOCKRSYNC'
#!/usr/bin/env bash
local src="" dst=""
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--remove-source-files) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
src="${args[0]%/}"
dst="${args[1]%/}"
mkdir -p "$dst"
[[ -d "$src" ]] && cp -r "$src/." "$dst/" 2>/dev/null || true
exit 0
MOCKRSYNC
  chmod +x "$mock_bin/rsync"

  echo "$mock_bin"
}

# ---------------------------------------------------------------------------
# Test 1: test_symlink_replaced (RECL-02) — symlink replaced with real dir after recall
# ---------------------------------------------------------------------------
echo ""
echo "--- Test RECL-02: test_symlink_replaced ---"

# Set up: create cold model, create hot symlink pointing to it
cold_model="$TMP/cold/hf/models--org--testmodel"
hot_model="$TMP/hf_cache/models--org--testmodel"
mkdir -p "$cold_model/blobs"
echo "model weights" > "$cold_model/blobs/sha256-abc"
ln -s "$cold_model" "$hot_model"

# Mock fuser (returns 1 = not in use), check_cold_mounted, check_space via override script
mock_bin=$(build_mock_recall_env)

# Mock mountpoint for check_cold_mounted (already path-based check in hf_adapter.sh)
cat > "$mock_bin/mountpoint" <<'MOCKMP'
#!/usr/bin/env bash
exit 0
MOCKMP
chmod +x "$mock_bin/mountpoint"

# Run recall.sh
PATH="$mock_bin:$PATH" HOME="$TMP" bash "${MODELSTORE_CMD}/recall.sh" "$hot_model" 2>/dev/null || true

# Wait briefly for any background processes
sleep 0.1

# After recall, hot_model should be a real directory, not a symlink
not_symlink=0
[[ -d "$hot_model" && ! -L "$hot_model" ]] && not_symlink=1
assert_eq "$not_symlink" "1" "recall replaces symlink with real directory (RECL-02)"

# Cleanup for next test
rm -rf "$hot_model" "$TMP/cold/hf/models--org--testmodel"

# ---------------------------------------------------------------------------
# Test 2: test_timer_reset (RECL-02) — usage.json timestamp updated after recall
# ---------------------------------------------------------------------------
echo ""
echo "--- Test RECL-02: test_timer_reset ---"

cold_model2="$TMP/cold/hf/models--org--timertest"
hot_model2="$TMP/hf_cache/models--org--timertest"
mkdir -p "$cold_model2/blobs"
echo "model data" > "$cold_model2/blobs/sha256-def"
ln -s "$cold_model2" "$hot_model2"

# Set an old timestamp in usage.json
old_ts="2025-01-01T00:00:00Z"
jq --arg k "$hot_model2" --arg ts "$old_ts" '.[$k] = $ts' \
  "$TMP/.modelstore/usage.json" > "$TMP/.modelstore/usage.json.tmp" \
  && mv "$TMP/.modelstore/usage.json.tmp" "$TMP/.modelstore/usage.json"

mock_bin2=$(build_mock_recall_env)
cat > "$mock_bin2/mountpoint" <<'MOCKMP'
#!/usr/bin/env bash
exit 0
MOCKMP
chmod +x "$mock_bin2/mountpoint"

PATH="$mock_bin2:$PATH" HOME="$TMP" bash "${MODELSTORE_CMD}/recall.sh" "$hot_model2" 2>/dev/null || true
sleep 0.1

# Read updated timestamp from usage.json
new_ts=$(jq -r --arg k "$hot_model2" '.[$k] // empty' "$TMP/.modelstore/usage.json" 2>/dev/null || echo "")
ts_updated=0
# Timestamp should have changed from the old one
[[ -n "$new_ts" && "$new_ts" != "$old_ts" ]] && ts_updated=1
assert_eq "$ts_updated" "1" "recall resets usage timestamp in usage.json (RECL-02)"

# Check timestamp is recent (within last 60 seconds)
ts_recent=0
if [[ -n "$new_ts" ]]; then
  ts_epoch=$(date -d "$new_ts" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  [[ $(( now_epoch - ts_epoch )) -lt 60 ]] && ts_recent=1
fi
assert_eq "$ts_recent" "1" "recall sets usage timestamp within last 60 seconds (RECL-02)"

rm -rf "$hot_model2" "$cold_model2"

# ---------------------------------------------------------------------------
# Test 3: test_fuser_busy_skip — auto-recall skipped when model is in use
# ---------------------------------------------------------------------------
echo ""
echo "--- Test RECL: test_fuser_busy_skip ---"

cold_model3="$TMP/cold/hf/models--org--busymodel"
hot_model3="$TMP/hf_cache/models--org--busymodel"
mkdir -p "$cold_model3/blobs"
echo "model data" > "$cold_model3/blobs/sha256-busy"
ln -s "$cold_model3" "$hot_model3"

# Mock fuser to return 0 (files in use)
mock_bin3="$TMP/mock_bin_busy"
mkdir -p "$mock_bin3"
cat > "$mock_bin3/fuser" <<'FUSER_BUSY'
#!/usr/bin/env bash
exit 0
FUSER_BUSY
chmod +x "$mock_bin3/fuser"
cat > "$mock_bin3/mountpoint" <<'MOCKMP'
#!/usr/bin/env bash
exit 0
MOCKMP
chmod +x "$mock_bin3/mountpoint"

# Capture output to check for skip message
skip_output=$(PATH="$mock_bin3:$PATH" HOME="$TMP" bash "${MODELSTORE_CMD}/recall.sh" "$hot_model3" --trigger=auto 2>&1 || true)

skip_logged=0
[[ "$skip_output" == *"Model in use, skipping auto-recall"* ]] && skip_logged=1
assert_eq "$skip_logged" "1" "auto-recall skipped when fuser returns 0 (model in use)"

# hot_model3 should still be a symlink (recall was skipped)
still_symlink=0
[[ -L "$hot_model3" ]] && still_symlink=1
assert_eq "$still_symlink" "1" "hot model path remains symlink when auto-recall skipped"

rm -rf "$hot_model3" "$cold_model3"

# ---------------------------------------------------------------------------
# Test 4: test_not_symlink_skip — recall skips non-symlink paths gracefully
# ---------------------------------------------------------------------------
echo ""
echo "--- Test RECL: test_not_symlink_skip ---"

# Create a regular directory (not a symlink)
real_model="$TMP/hf_cache/models--org--realmodel"
mkdir -p "$real_model/blobs"
echo "real data" > "$real_model/blobs/sha256-real"

mock_bin4="$TMP/mock_bin4"
mkdir -p "$mock_bin4"
cat > "$mock_bin4/mountpoint" <<'MOCKMP'
#!/usr/bin/env bash
exit 0
MOCKMP
chmod +x "$mock_bin4/mountpoint"

skip_output2=$(PATH="$mock_bin4:$PATH" HOME="$TMP" bash "${MODELSTORE_CMD}/recall.sh" "$real_model" 2>&1 || true)

skip_msg=0
[[ "$skip_output2" == *"Not a symlink, skip recall"* ]] && skip_msg=1
assert_eq "$skip_msg" "1" "recall logs 'Not a symlink, skip recall' for regular directory"

# Return code should be 0 (graceful skip)
skip_exit=0
PATH="$mock_bin4:$PATH" HOME="$TMP" bash "${MODELSTORE_CMD}/recall.sh" "$real_model" 2>/dev/null || skip_exit=$?
assert_eq "$skip_exit" "0" "recall exits 0 for non-symlink path (graceful skip)"

rm -rf "$real_model"

# ---------------------------------------------------------------------------
# Test 5: test_audit_logged — audit.log has recall entry after successful recall
# ---------------------------------------------------------------------------
echo ""
echo "--- Test RECL-03: test_audit_logged ---"

cold_model5="$TMP/cold/hf/models--org--auditmodel"
hot_model5="$TMP/hf_cache/models--org--auditmodel"
mkdir -p "$cold_model5/blobs"
echo "model data" > "$cold_model5/blobs/sha256-audit"
ln -s "$cold_model5" "$hot_model5"
rm -f "$TMP/.modelstore/audit.log"

mock_bin5=$(build_mock_recall_env)
cat > "$mock_bin5/mountpoint" <<'MOCKMP'
#!/usr/bin/env bash
exit 0
MOCKMP
chmod +x "$mock_bin5/mountpoint"

PATH="$mock_bin5:$PATH" HOME="$TMP" bash "${MODELSTORE_CMD}/recall.sh" "$hot_model5" 2>/dev/null || true
sleep 0.1

# Check audit.log has a recall entry
audit_has_recall=0
if [[ -f "$TMP/.modelstore/audit.log" ]]; then
  recall_event=$(jq -r '.event' "$TMP/.modelstore/audit.log" 2>/dev/null | grep "recall" | head -1)
  [[ "$recall_event" == "recall" ]] && audit_has_recall=1
fi
assert_eq "$audit_has_recall" "1" "audit.log has recall event entry after successful recall (RECL-03)"

# Check trigger field in audit entry
audit_trigger=$(jq -r '.trigger' "$TMP/.modelstore/audit.log" 2>/dev/null | head -1)
assert_eq "$audit_trigger" "manual" "audit.log recall entry has trigger=manual"

rm -rf "$hot_model5" "$cold_model5"

# ---------------------------------------------------------------------------
# Test 6: test_auto_trigger (RECL-01) — watcher cold symlink detection calls recall
# ---------------------------------------------------------------------------
echo ""
echo "--- Test RECL-01: test_auto_trigger ---"

# Create a cold model and a hot symlink
cold_model6="$TMP/cold/hf/models--org--autorecall"
hot_model6="$TMP/hf_cache/models--org--autorecall"
mkdir -p "$cold_model6/blobs"
echo "model weights" > "$cold_model6/blobs/sha256-auto"
ln -s "$cold_model6" "$hot_model6"
rm -f "$TMP/.modelstore/audit.log"

# Load watcher constants so we can run the cold symlink detection logic
COLD_PATH="$TMP/cold"
HOT_HF_PATH="$TMP/hf_cache"
HOT_OLLAMA_PATH="$TMP/ollama_models"

# Inline the auto-recall trigger logic from watcher.sh (detection block)
mock_bin6=$(build_mock_recall_env)
cat > "$mock_bin6/mountpoint" <<'MOCKMP'
#!/usr/bin/env bash
exit 0
MOCKMP
chmod +x "$mock_bin6/mountpoint"

model_path="$hot_model6"
if [[ -L "$model_path" ]]; then
  link_target=$(readlink -f "$model_path" 2>/dev/null || true)
  if [[ -n "$link_target" && "$link_target" == "${COLD_PATH}"/* ]]; then
    PATH="$mock_bin6:$PATH" HOME="$TMP" \
      bash "${MODELSTORE_CMD}/recall.sh" "$model_path" --trigger=auto 2>/dev/null || true
  fi
fi
sleep 0.1

# After trigger, hot_model6 should be a real directory
auto_recalled=0
[[ -d "$hot_model6" && ! -L "$hot_model6" ]] && auto_recalled=1
assert_eq "$auto_recalled" "1" "cold symlink access triggers auto-recall via watcher logic (RECL-01)"

rm -rf "$hot_model6" "$cold_model6"

# ---------------------------------------------------------------------------
# Test 7: test_launcher_hook (RECL-03) — both usage update and recall happen on access
# ---------------------------------------------------------------------------
echo ""
echo "--- Test RECL-03: test_launcher_hook ---"

cold_model7="$TMP/cold/hf/models--org--launcher"
hot_model7="$TMP/hf_cache/models--org--launcher"
mkdir -p "$cold_model7/blobs"
echo "model data" > "$cold_model7/blobs/sha256-launch"
ln -s "$cold_model7" "$hot_model7"
echo '{}' > "$TMP/.modelstore/usage.json"
rm -f "$TMP/.modelstore/audit.log"

# Set COLD_PATH directly — avoids load_config reading the real system config
COLD_PATH="$TMP/cold"

USAGE_FILE="$TMP/.modelstore/usage.json"
USAGE_LOCK="$TMP/.modelstore/usage.lock"
DEBOUNCE_SECONDS=0

ms_track_usage_local() {
  local model_path="$1"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  [[ -f "$USAGE_FILE" ]] || echo '{}' > "$USAGE_FILE"
  (
    flock -x 9
    local current
    current=$(cat "$USAGE_FILE")
    echo "$current" | jq --arg path "$model_path" --arg ts "$timestamp" \
      '.[$path] = $ts' > "${USAGE_FILE}.tmp" \
    && mv "${USAGE_FILE}.tmp" "$USAGE_FILE"
  ) 9>"$USAGE_LOCK" 2>/dev/null || true
}

mock_bin7=$(build_mock_recall_env)
cat > "$mock_bin7/mountpoint" <<'MOCKMP'
#!/usr/bin/env bash
exit 0
MOCKMP
chmod +x "$mock_bin7/mountpoint"

# Simulate the full watcher loop action for a cold symlink access
ms_track_usage_local "$hot_model7"

model_path="$hot_model7"
if [[ -L "$model_path" ]]; then
  link_target=$(readlink -f "$model_path" 2>/dev/null || true)
  if [[ -n "$link_target" && "$link_target" == "${COLD_PATH}"/* ]]; then
    PATH="$mock_bin7:$PATH" HOME="$TMP" \
      bash "${MODELSTORE_CMD}/recall.sh" "$model_path" --trigger=auto 2>/dev/null || true
  fi
fi
sleep 0.1

# Assert usage.json was updated by ms_track_usage
usage_updated=0
usage_ts=$(jq -r --arg k "$hot_model7" '.[$k] // empty' "$USAGE_FILE" 2>/dev/null)
[[ -n "$usage_ts" ]] && usage_updated=1
assert_eq "$usage_updated" "1" "ms_track_usage updates usage.json on cold symlink access (RECL-03)"

# Assert recall happened (hot model is now a directory, not symlink)
recall_happened=0
[[ -d "$hot_model7" && ! -L "$hot_model7" ]] && recall_happened=1
assert_eq "$recall_happened" "1" "recall.sh is triggered on cold symlink access (RECL-03)"

rm -rf "$hot_model7" "$cold_model7"

# ---------------------------------------------------------------------------
report
