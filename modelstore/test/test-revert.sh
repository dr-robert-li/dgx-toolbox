#!/usr/bin/env bash
# modelstore/test/test-revert.sh — Tests for cmd/revert.sh
# Covers: REVT-01 through REVT-12
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELSTORE_LIB="${SCRIPT_DIR}/../lib"
MODELSTORE_CMD="${SCRIPT_DIR}/../cmd"

PASS=0; FAIL=0
assert_eq() { if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1)); echo "  PASS: $3"; else FAIL=$((FAIL + 1)); echo "  FAIL: $3 (expected '$2', got '$1')"; fi; }
assert_ok() { if eval "$1" 2>/dev/null; then PASS=$((PASS + 1)); echo "  PASS: $2"; else FAIL=$((FAIL + 1)); echo "  FAIL: $2"; fi; }
report() { echo ""; echo "Results: $PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]; }

echo "=== Revert Tests ==="

# ---------------------------------------------------------------------------
# Setup: temp environment
# ---------------------------------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.modelstore"
mkdir -p "$TMP/hf_cache"
mkdir -p "$TMP/cold_mount/hf"
mkdir -p "$TMP/cold_mount/ollama"
mkdir -p "$TMP/ollama_models"

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
# Helper: run_revert <args...>
# Runs revert.sh with check_cold_mounted overridden to accept any directory.
# Uses a mock cmd script that: sources real libs, then redefines check_cold_mounted,
# then runs the revert logic by sourcing only the body of revert.sh.
# ---------------------------------------------------------------------------

MOCK_CMD="$TMP/mock_cmd"
mkdir -p "$MOCK_CMD"

# Create mock revert.sh: sources real libs, overrides check_cold_mounted,
# then inlines the revert logic (lines 21+ from real revert.sh = after source block).
REAL_LIB="${MODELSTORE_LIB}"
{
  echo "#!/usr/bin/env bash"
  echo "set -euo pipefail"
  echo "SCRIPT_DIR=\"${MODELSTORE_CMD}\""
  echo "source \"${REAL_LIB}/common.sh\""
  echo "source \"${REAL_LIB}/config.sh\""
  echo "source \"${REAL_LIB}/hf_adapter.sh\""
  echo "source \"${REAL_LIB}/ollama_adapter.sh\""
  echo "source \"${REAL_LIB}/audit.sh\""
  echo "# Test override: treat dir existence as mounted"
  echo "check_cold_mounted() {"
  echo "  local cold_path=\"\$1\""
  echo "  [[ -d \"\$cold_path\" ]] || { echo \"[modelstore] ERROR: Cold drive not mounted: \$cold_path\" >&2; exit 1; }"
  echo "}"
  # Append lines 21+ (after the source block) from real revert.sh
  tail -n +21 "${MODELSTORE_CMD}/revert.sh"
} > "$MOCK_CMD/revert.sh"
chmod +x "$MOCK_CMD/revert.sh"

run_revert() {
  HOME="$TMP" bash "$MOCK_CMD/revert.sh" "$@"
}

# ---------------------------------------------------------------------------
# Test REVT-01: --force recalls all migrated models (symlink replaced with real dir)
# ---------------------------------------------------------------------------
echo ""
echo "--- Test REVT-01: force_recalls_all ---"

mkdir -p "$TMP/cold_mount/hf/models--org--model1/blobs"
echo "data" > "$TMP/cold_mount/hf/models--org--model1/blobs/sha256-m1"
ln -s "$TMP/cold_mount/hf/models--org--model1" "$TMP/hf_cache/models--org--model1"

run_revert --force 2>&1 | tee "$TMP/revert01_output.txt" || true

revt01_ok=0
if [[ ! -L "$TMP/hf_cache/models--org--model1" ]] && [[ -d "$TMP/hf_cache/models--org--model1" ]]; then
  revt01_ok=1
fi
assert_eq "$revt01_ok" "1" "revert --force recalls all symlinked models (REVT-01)"

rm -rf "$TMP/hf_cache/models--org--model1"
mkdir -p "$TMP/cold_mount/hf"
rm -f "$TMP/.modelstore/op_state.json"

# ---------------------------------------------------------------------------
# Test REVT-02: revert removes cron entries
# ---------------------------------------------------------------------------
echo ""
echo "--- Test REVT-02: removes_cron ---"

# Run revert --force and verify cron cleanup is mentioned in output
run_revert --force 2>&1 | tee "$TMP/revert02_output.txt" || true

revt02_ok=0
grep -qi "cron\|Cron" "$TMP/revert02_output.txt" 2>/dev/null && revt02_ok=1
assert_eq "$revt02_ok" "1" "revert.sh logs cron cleanup step (REVT-02)"
rm -f "$TMP/.modelstore/op_state.json"

# ---------------------------------------------------------------------------
# Test REVT-03: revert stops watcher (kills PID and removes pidfile)
# ---------------------------------------------------------------------------
echo ""
echo "--- Test REVT-03: stops_watcher ---"

sleep 9999 &
FAKE_PID=$!
echo "$FAKE_PID" > "$TMP/.modelstore/watcher.pid"

run_revert --force 2>&1 | tee "$TMP/revert03_output.txt" || true

revt03_pid_killed=0
kill -0 "$FAKE_PID" 2>/dev/null || revt03_pid_killed=1

revt03_pidfile_removed=0
[[ ! -f "$TMP/.modelstore/watcher.pid" ]] && revt03_pidfile_removed=1

assert_eq "$revt03_pid_killed" "1" "watcher process killed by revert (REVT-03)"
assert_eq "$revt03_pidfile_removed" "1" "watcher pidfile removed by revert (REVT-03)"

kill "$FAKE_PID" 2>/dev/null || true
rm -f "$TMP/.modelstore/op_state.json"

# ---------------------------------------------------------------------------
# Test REVT-04: revert removes cold storage modelstore dirs
# ---------------------------------------------------------------------------
echo ""
echo "--- Test REVT-04: removes_cold_dirs ---"

mkdir -p "$TMP/cold_mount/hf/models--org--somemodel"
mkdir -p "$TMP/cold_mount/ollama/models"

run_revert --force 2>&1 | tee "$TMP/revert04_output.txt" || true

revt04_ok=0
if [[ ! -d "$TMP/cold_mount/hf" ]] && [[ ! -d "$TMP/cold_mount/ollama" ]]; then
  revt04_ok=1
fi
assert_eq "$revt04_ok" "1" "cold_mount/hf and cold_mount/ollama removed by revert (REVT-04)"

rm -f "$TMP/.modelstore/op_state.json"
mkdir -p "$TMP/cold_mount/hf"

# ---------------------------------------------------------------------------
# Test REVT-05: revert KEEPS ~/.modelstore/config.json
# ---------------------------------------------------------------------------
echo ""
echo "--- Test REVT-05: keeps_config ---"

run_revert --force 2>&1 | tee "$TMP/revert05_output.txt" || true

revt05_ok=0
[[ -f "$TMP/.modelstore/config.json" ]] && revt05_ok=1
assert_eq "$revt05_ok" "1" "revert keeps ~/.modelstore/config.json (REVT-05)"
rm -f "$TMP/.modelstore/op_state.json"

# ---------------------------------------------------------------------------
# Test REVT-06: Interrupt resume — completed_models skips already reverted
# ---------------------------------------------------------------------------
echo ""
echo "--- Test REVT-06: interrupt_resume ---"

mkdir -p "$TMP/cold_mount/hf/models--org--m1/blobs"
echo "data" > "$TMP/cold_mount/hf/models--org--m1/blobs/sha256-m1"
ln -s "$TMP/cold_mount/hf/models--org--m1" "$TMP/hf_cache/models--org--m1"

mkdir -p "$TMP/cold_mount/hf/models--org--m2/blobs"
echo "data" > "$TMP/cold_mount/hf/models--org--m2/blobs/sha256-m2"
ln -s "$TMP/cold_mount/hf/models--org--m2" "$TMP/hf_cache/models--org--m2"

# Pre-create op_state.json indicating m1 was already completed
m1_path="${TMP}/hf_cache/models--org--m1"
jq -n \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg m1 "$m1_path" \
  '{op:"revert",phase:"recall_hf",started_at:$ts,trigger:"manual",completed_models:[$m1],total_models:2}' \
  > "$TMP/.modelstore/op_state.json"

run_revert --force 2>&1 | tee "$TMP/revert06_output.txt" || true

# m2 should be recalled (no longer a symlink)
revt06_ok=0
[[ ! -L "$TMP/hf_cache/models--org--m2" ]] && revt06_ok=1
assert_eq "$revt06_ok" "1" "interrupt resume recalls remaining model (m2 not in completed_models) (REVT-06)"

rm -rf "$TMP/hf_cache/models--org--m1" "$TMP/hf_cache/models--org--m2"
rm -rf "$TMP/cold_mount/hf"
mkdir -p "$TMP/cold_mount/hf"
rm -f "$TMP/.modelstore/op_state.json"

# ---------------------------------------------------------------------------
# Test REVT-07: --force flag skips confirmation (no stdin read, exits 0)
# ---------------------------------------------------------------------------
echo ""
echo "--- Test REVT-07: force_skips_confirm ---"

revt07_exit=0
run_revert --force </dev/null 2>&1 | tee "$TMP/revert07_output.txt" || revt07_exit=$?
assert_eq "$revt07_exit" "0" "--force skips confirmation prompt and exits 0 (REVT-07)"
rm -f "$TMP/.modelstore/op_state.json"

# ---------------------------------------------------------------------------
# Test REVT-08: Without --force and without TTY, revert exits nonzero
# ---------------------------------------------------------------------------
echo ""
echo "--- Test REVT-08: no_force_no_tty_exits ---"

revt08_exit=0
run_revert </dev/null 2>&1 | tee "$TMP/revert08_output.txt" || revt08_exit=$?

revt08_ok=0
[[ "$revt08_exit" -ne 0 ]] && revt08_ok=1
assert_eq "$revt08_ok" "1" "revert without --force and without TTY exits nonzero (REVT-08)"
rm -f "$TMP/.modelstore/op_state.json"

# ---------------------------------------------------------------------------
# Test REVT-09: revert aborts if cold drive is not mounted
# ---------------------------------------------------------------------------
echo ""
echo "--- Test REVT-09: aborts_if_cold_not_mounted ---"

# Point config to a path that is NOT a directory (simulates unmounted)
COLD_NOT_EXIST="$TMP/definitely_not_mounted"
cat > "$TMP/.modelstore/config.json" <<ENDCONFIG2
{
  "version": 1,
  "hot_hf_path": "${TMP}/hf_cache",
  "hot_ollama_path": "${TMP}/ollama_models",
  "cold_path": "${COLD_NOT_EXIST}",
  "retention_days": 14,
  "cron_hour": 2,
  "backup_retention_days": 30,
  "created_at": "2026-01-01T00:00:00Z",
  "updated_at": "2026-01-01T00:00:00Z"
}
ENDCONFIG2

# Use the real revert.sh (with check_cold_mounted intact) to test mount check failure
revt09_exit=0
HOME="$TMP" bash "${MODELSTORE_CMD}/revert.sh" --force 2>&1 | tee "$TMP/revert09_output.txt" || revt09_exit=$?

revt09_ok=0
[[ "$revt09_exit" -ne 0 ]] && revt09_ok=1
assert_eq "$revt09_ok" "1" "revert aborts (exit nonzero) when cold drive not mounted (REVT-09)"

# Restore proper config
cat > "$TMP/.modelstore/config.json" <<ENDCONFIG3
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
ENDCONFIG3
rm -f "$TMP/.modelstore/op_state.json"

# ---------------------------------------------------------------------------
# Test REVT-10: revert aborts if op_state.json has .op != "revert" and age < 4 hours
# ---------------------------------------------------------------------------
echo ""
echo "--- Test REVT-10: aborts_conflicting_op_fresh ---"

fresh_ts=$(date -d "1 minute ago" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n \
  --arg ts "$fresh_ts" \
  '{op:"migrate",model:"/test/model",phase:"rsync",started_at:$ts,trigger:"cron"}' \
  > "$TMP/.modelstore/op_state.json"

revt10_exit=0
run_revert --force 2>&1 | tee "$TMP/revert10_output.txt" || revt10_exit=$?

revt10_ok=0
[[ "$revt10_exit" -ne 0 ]] && revt10_ok=1
assert_eq "$revt10_ok" "1" "revert aborts when fresh non-revert op_state.json exists (REVT-10)"

rm -f "$TMP/.modelstore/op_state.json"

# ---------------------------------------------------------------------------
# Test REVT-11: revert clears stale op_state.json (.op != "revert", age > 4 hours)
# ---------------------------------------------------------------------------
echo ""
echo "--- Test REVT-11: clears_stale_op_state ---"

stale_ts=$(date -d "5 hours ago" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2026-03-21T15:00:00Z")
jq -n \
  --arg ts "$stale_ts" \
  '{op:"migrate",model:"/test/model",phase:"rsync",started_at:$ts,trigger:"cron"}' \
  > "$TMP/.modelstore/op_state.json"

revt11_output=""
revt11_output=$(run_revert --force 2>&1 || true)

revt11_ok=0
echo "$revt11_output" | grep -qi "stale\|clearing" && revt11_ok=1
assert_eq "$revt11_ok" "1" "revert clears stale op_state.json (>4h, non-revert op) and proceeds (REVT-11)"

rm -f "$TMP/.modelstore/op_state.json"

# ---------------------------------------------------------------------------
# Test REVT-12: op_state.json cleared after successful revert (completed_models tracking)
# ---------------------------------------------------------------------------
echo ""
echo "--- Test REVT-12: completed_models_tracking ---"

mkdir -p "$TMP/cold_mount/hf/models--org--track-model/blobs"
echo "data" > "$TMP/cold_mount/hf/models--org--track-model/blobs/sha256-t1"
ln -s "$TMP/cold_mount/hf/models--org--track-model" "$TMP/hf_cache/models--org--track-model"

run_revert --force 2>&1 | tee "$TMP/revert12_output.txt" || true

revt12_ok=0
[[ ! -f "$TMP/.modelstore/op_state.json" ]] && revt12_ok=1
assert_eq "$revt12_ok" "1" "op_state.json cleared after successful revert (REVT-12)"

rm -rf "$TMP/hf_cache/models--org--track-model"
rm -rf "$TMP/cold_mount/hf"
mkdir -p "$TMP/cold_mount/hf"

# ---------------------------------------------------------------------------
report
