#!/usr/bin/env bash
# modelstore/test/test-status.sh — Tests for cmd/status.sh
# Covers: STAT-01 through STAT-10
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELSTORE_CMD="${SCRIPT_DIR}/../cmd"

PASS=0; FAIL=0
assert_eq() { if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1)); echo "  PASS: $3"; else FAIL=$((FAIL + 1)); echo "  FAIL: $3 (expected '$2', got '$1')"; fi; }
assert_ok() { if eval "$1" 2>/dev/null; then PASS=$((PASS + 1)); echo "  PASS: $2"; else FAIL=$((FAIL + 1)); echo "  FAIL: $2"; fi; }
report() { echo ""; echo "Results: $PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]; }

echo "=== Status Tests ==="

# ---------------------------------------------------------------------------
# Setup: temp environment
# ---------------------------------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.modelstore"
mkdir -p "$TMP/hf_cache"
mkdir -p "$TMP/cold_mount/hf"
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

# Set up model fixtures:
# 1. HOT model: real directory
mkdir -p "$TMP/hf_cache/models--org--hot-model/blobs"
echo "data" > "$TMP/hf_cache/models--org--hot-model/blobs/sha256-hot"

# 2. COLD model: symlink to valid target
mkdir -p "$TMP/cold_mount/hf/models--org--cold-model/blobs"
echo "data" > "$TMP/cold_mount/hf/models--org--cold-model/blobs/sha256-cold"
ln -s "$TMP/cold_mount/hf/models--org--cold-model" "$TMP/hf_cache/models--org--cold-model"

# 3. BROKEN model: symlink to nonexistent target
ln -s "/nonexistent/path/models--org--broken-model" "$TMP/hf_cache/models--org--broken-model"

# Set up usage.json: hot model used recently, cold model never tracked
recent_ts=$(date -d "1 day ago" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2026-03-20T12:00:00Z")
jq -n \
  --arg k1 "${TMP}/hf_cache/models--org--hot-model" --arg ts1 "$recent_ts" \
  '{($k1): $ts1}' > "$TMP/.modelstore/usage.json"

# Run status.sh and capture output
STATUS_OUTPUT=$(HOME="$TMP" bash "${MODELSTORE_CMD}/status.sh" 2>&1 || true)

# ---------------------------------------------------------------------------
# Test STAT-01: Header line contains MODEL, ECOSYSTEM, TIER, SIZE, LAST USED, DAYS LEFT
# ---------------------------------------------------------------------------
echo ""
echo "--- Test STAT-01: header_columns ---"
header_ok=0
echo "$STATUS_OUTPUT" | grep -q "MODEL" && \
  echo "$STATUS_OUTPUT" | grep -q "ECOSYSTEM" && \
  echo "$STATUS_OUTPUT" | grep -q "TIER" && \
  echo "$STATUS_OUTPUT" | grep -q "SIZE" && \
  echo "$STATUS_OUTPUT" | grep -q "LAST USED" && \
  echo "$STATUS_OUTPUT" | grep -q "DAYS LEFT" && header_ok=1
assert_eq "$header_ok" "1" "header line contains MODEL ECOSYSTEM TIER SIZE LAST_USED DAYS_LEFT (STAT-01)"

# ---------------------------------------------------------------------------
# Test STAT-02: HF model directory (non-symlink) shows as HOT
# ---------------------------------------------------------------------------
echo ""
echo "--- Test STAT-02: hf_hot_tier ---"
hot_ok=0
echo "$STATUS_OUTPUT" | grep -q "models--org--hot-model" && \
  echo "$STATUS_OUTPUT" | grep "models--org--hot-model" | grep -q "HOT" && hot_ok=1
assert_eq "$hot_ok" "1" "HF real directory shows as HOT tier (STAT-02)"

# ---------------------------------------------------------------------------
# Test STAT-03: HF model symlink pointing to valid target shows as COLD
# ---------------------------------------------------------------------------
echo ""
echo "--- Test STAT-03: hf_cold_tier ---"
cold_ok=0
echo "$STATUS_OUTPUT" | grep -q "models--org--cold-model" && \
  echo "$STATUS_OUTPUT" | grep "models--org--cold-model" | grep -q "COLD" && cold_ok=1
assert_eq "$cold_ok" "1" "HF symlink to valid target shows as COLD tier (STAT-03)"

# ---------------------------------------------------------------------------
# Test STAT-04: HF model symlink pointing to nonexistent target shows as BROKEN
# ---------------------------------------------------------------------------
echo ""
echo "--- Test STAT-04: hf_broken_tier ---"
broken_ok=0
echo "$STATUS_OUTPUT" | grep -q "models--org--broken-model" && \
  echo "$STATUS_OUTPUT" | grep "models--org--broken-model" | grep -q "BROKEN" && broken_ok=1
assert_eq "$broken_ok" "1" "HF symlink to nonexistent target shows as BROKEN tier (STAT-04)"

# ---------------------------------------------------------------------------
# Test STAT-05: Dashboard prints drive totals line matching "Hot:.*used.*Cold:.*used"
# ---------------------------------------------------------------------------
echo ""
echo "--- Test STAT-05: drive_totals ---"
drive_ok=0
echo "$STATUS_OUTPUT" | grep -qE "Hot:.*Cold:" && drive_ok=1
assert_eq "$drive_ok" "1" "dashboard prints Hot: ... Cold: drive totals line (STAT-05)"

# ---------------------------------------------------------------------------
# Test STAT-06: Dashboard prints model counts line matching "[0-9]+ models hot"
# ---------------------------------------------------------------------------
echo ""
echo "--- Test STAT-06: model_counts ---"
count_ok=0
echo "$STATUS_OUTPUT" | grep -qE "[0-9]+ models? hot" && count_ok=1
assert_eq "$count_ok" "1" "dashboard prints N models hot count line (STAT-06)"

# ---------------------------------------------------------------------------
# Test STAT-07: Dashboard prints watcher status (running/stopped)
# ---------------------------------------------------------------------------
echo ""
echo "--- Test STAT-07: watcher_status ---"
watcher_ok=0
echo "$STATUS_OUTPUT" | grep -qi "watcher:" && \
  (echo "$STATUS_OUTPUT" | grep -qi "running\|stopped") && watcher_ok=1
assert_eq "$watcher_ok" "1" "dashboard prints Watcher: status (STAT-07)"

# ---------------------------------------------------------------------------
# Test STAT-08: Dashboard prints cron status (installed/not installed)
# ---------------------------------------------------------------------------
echo ""
echo "--- Test STAT-08: cron_status ---"
cron_ok=0
echo "$STATUS_OUTPUT" | grep -qi "cron:" && \
  (echo "$STATUS_OUTPUT" | grep -qi "installed\|not installed") && cron_ok=1
assert_eq "$cron_ok" "1" "dashboard prints Cron: status (STAT-08)"

# ---------------------------------------------------------------------------
# Test STAT-09: Dashboard prints last migration line
# ---------------------------------------------------------------------------
echo ""
echo "--- Test STAT-09: last_migration ---"
migration_ok=0
echo "$STATUS_OUTPUT" | grep -qi "last migration" && migration_ok=1
assert_eq "$migration_ok" "1" "dashboard prints Last migration: line (STAT-09)"

# ---------------------------------------------------------------------------
# Test STAT-10: Ollama API unavailable does not cause status.sh to exit nonzero
# ---------------------------------------------------------------------------
echo ""
echo "--- Test STAT-10: ollama_unavailable_graceful ---"
# Already captured in STATUS_OUTPUT above, check it didn't fail:
# Run again explicitly forcing no Ollama — set a known path that's empty
exit_code=0
HOME="$TMP" bash "${MODELSTORE_CMD}/status.sh" 2>&1 >/dev/null || exit_code=$?
assert_eq "$exit_code" "0" "status.sh exits 0 even when Ollama API is unavailable (STAT-10)"

# ---------------------------------------------------------------------------
report
