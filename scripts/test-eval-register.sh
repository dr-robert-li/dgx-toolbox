#!/usr/bin/env bash
# test-eval-register.sh — Tests for TRSF-01/02/03 and MREG-01/02/03
#
# Usage: bash scripts/test-eval-register.sh
#
# Covers:
#   TRSF-01: eval-checkpoint.sh validates checkpoint dir has config.json
#   TRSF-02: eval-checkpoint.sh exits 0 on failed safety eval (non-destructive)
#   TRSF-03: safety-eval.json is written to checkpoint dir
#   MREG-01: _litellm_register.py add appends model entry to config
#   MREG-02: Registered model entry follows correct YAML schema
#   MREG-03: autoresearch-deregister.sh / remove command works
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
ERRORS=()

# ---------------------------------------------------------------------------
# Helper: assertion primitives
# ---------------------------------------------------------------------------
_pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

_fail() {
  FAIL=$((FAIL + 1))
  ERRORS+=("FAIL: $1")
  echo "  FAIL: $1"
}

_assert_exit_nonzero() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    _fail "$name: expected non-zero exit but got 0"
  else
    _pass "$name"
  fi
}

_assert_exit_zero() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    _pass "$name"
  else
    _fail "$name: expected exit 0 but got non-zero"
  fi
}

_assert_contains() {
  local name="$1" pattern="$2" text="$3"
  if echo "$text" | grep -qi "$pattern"; then
    _pass "$name"
  else
    _fail "$name: output did not contain '$pattern'"
  fi
}

_assert_not_contains() {
  local name="$1" pattern="$2" text="$3"
  if echo "$text" | grep -qi "$pattern"; then
    _fail "$name: output unexpectedly contained '$pattern'"
  else
    _pass "$name"
  fi
}

# ---------------------------------------------------------------------------
# Helper: create temp LiteLLM config copy with patched CONFIG_PATH
# Returns: path to patched temp script
# ---------------------------------------------------------------------------
_make_patched_register() {
  local tmp_config="$1"
  local tmp_script
  tmp_script=$(mktemp /tmp/litellm_register_XXXXXX.py)
  # Copy script and replace the CONFIG_PATH line to point at tmp_config
  sed "s|CONFIG_PATH = os.path.expanduser.*|CONFIG_PATH = '${tmp_config}'|" \
    "${SCRIPT_DIR}/_litellm_register.py" > "$tmp_script"
  echo "$tmp_script"
}

# ---------------------------------------------------------------------------
# TRSF-01: eval-checkpoint.sh validates checkpoint dir has config.json
# ---------------------------------------------------------------------------
echo ""
echo "=== TRSF-01: Checkpoint validation ==="

test_eval_checkpoint_syntax() {
  _assert_exit_zero "TRSF-01 eval-checkpoint.sh syntax valid" \
    bash -n "${SCRIPT_DIR}/eval-checkpoint.sh"
}

test_eval_checkpoint_requires_config_json() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  # Directory exists but no config.json — should exit non-zero
  local tmp_out exit_code output
  tmp_out=$(mktemp)
  set +e
  bash "${SCRIPT_DIR}/eval-checkpoint.sh" "$tmp_dir" >"$tmp_out" 2>&1
  exit_code=$?
  set -e
  output=$(cat "$tmp_out")
  rm -rf "$tmp_dir" "$tmp_out"
  if [ "$exit_code" -eq 0 ]; then
    _fail "TRSF-01 missing config.json should exit non-zero (got 0)"
  else
    _pass "TRSF-01 missing config.json exits non-zero"
  fi
  _assert_contains "TRSF-01 output mentions config.json" "config.json" "$output"
}

test_eval_checkpoint_requires_dir() {
  # Passing a non-existent path should exit non-zero
  local tmp_out exit_code
  tmp_out=$(mktemp)
  set +e
  bash "${SCRIPT_DIR}/eval-checkpoint.sh" "/tmp/nonexistent_checkpoint_dir_$$" >"$tmp_out" 2>&1
  exit_code=$?
  set -e
  rm -f "$tmp_out"
  if [ "$exit_code" -eq 0 ]; then
    _fail "TRSF-01 non-existent dir should exit non-zero (got 0)"
  else
    _pass "TRSF-01 non-existent dir exits non-zero"
  fi
}

test_eval_checkpoint_syntax
test_eval_checkpoint_requires_config_json
test_eval_checkpoint_requires_dir

# ---------------------------------------------------------------------------
# TRSF-02: eval-checkpoint.sh exits 0 on failed safety eval (non-destructive)
# ---------------------------------------------------------------------------
echo ""
echo "=== TRSF-02: Non-destructive fail behavior ==="

test_eval_checkpoint_nondestruct() {
  # Grep for WARNING.*FAILED in eval-checkpoint.sh
  if grep -q "WARNING.*Safety eval FAILED" "${SCRIPT_DIR}/eval-checkpoint.sh"; then
    _pass "TRSF-02 script contains WARNING on failure"
  else
    _fail "TRSF-02 script missing WARNING on failure"
  fi
  # Verify exit 0 follows the failure path
  if grep -q "exit 0" "${SCRIPT_DIR}/eval-checkpoint.sh"; then
    _pass "TRSF-02 script has exit 0 (non-destructive)"
  else
    _fail "TRSF-02 script missing exit 0 after failure"
  fi
}

test_eval_checkpoint_nondestruct

# ---------------------------------------------------------------------------
# TRSF-03: safety-eval.json written to checkpoint dir
# ---------------------------------------------------------------------------
echo ""
echo "=== TRSF-03: safety-eval.json output ==="

test_safety_eval_json_pattern() {
  # Confirm safety-eval.json is written to checkpoint dir (code-level check)
  if grep -q "safety-eval.json" "${SCRIPT_DIR}/eval-checkpoint.sh"; then
    _pass "TRSF-03 eval-checkpoint.sh references safety-eval.json"
  else
    _fail "TRSF-03 eval-checkpoint.sh missing safety-eval.json reference"
  fi
  # Confirm write pattern: redirect to checkpoint dir
  if grep -qE '>\s+.*CHECKPOINT_DIR.*safety-eval\.json' "${SCRIPT_DIR}/eval-checkpoint.sh"; then
    _pass "TRSF-03 safety-eval.json written to checkpoint dir"
  else
    _fail "TRSF-03 safety-eval.json write-to-checkpoint-dir pattern not found"
  fi
}

test_safety_eval_json_pattern

# ---------------------------------------------------------------------------
# MREG-01: _litellm_register.py add appends model entry
# ---------------------------------------------------------------------------
echo ""
echo "=== MREG-01: LiteLLM model registration ==="

test_litellm_register_add() {
  # Create temp config with empty model_list
  local tmp_config
  tmp_config=$(mktemp /tmp/litellm_config_XXXXXX.yaml)
  cat > "$tmp_config" << 'YAML'
model_list: []
litellm_settings:
  drop_params: true
YAML

  local tmp_script
  tmp_script=$(_make_patched_register "$tmp_config")

  local output
  output=$(python3 "$tmp_script" add "test-model" "http://localhost:8021/v1" 2>&1)
  local exit_code=$?
  rm -f "$tmp_script"

  if [ "$exit_code" -ne 0 ]; then
    _fail "MREG-01 _litellm_register.py add exited non-zero: $output"
    rm -f "$tmp_config"
    return
  fi

  if grep -q "model_name: test-model" "$tmp_config"; then
    _pass "MREG-01 model entry added to config"
  else
    _fail "MREG-01 model_name: test-model not found in config after add"
  fi

  # Store path for MREG-02 test
  export _MREG_TEST_CONFIG="$tmp_config"
}

test_litellm_register_add

# ---------------------------------------------------------------------------
# MREG-02: Registered model entry follows correct YAML schema
# ---------------------------------------------------------------------------
echo ""
echo "=== MREG-02: Registered model schema ==="

test_litellm_register_schema() {
  local tmp_config="${_MREG_TEST_CONFIG:-}"
  if [ -z "$tmp_config" ] || [ ! -f "$tmp_config" ]; then
    _fail "MREG-02 skipped: no tmp config from MREG-01"
    return
  fi

  local content
  content=$(cat "$tmp_config")

  _assert_contains "MREG-02 has litellm_params:" "litellm_params:" "$content"
  _assert_contains "MREG-02 has model: openai/test-model" "openai/test-model" "$content"
  _assert_contains "MREG-02 has api_base:" "api_base:" "$content"
  _assert_contains "MREG-02 has api_key:" "api_key:" "$content"
}

test_litellm_register_schema

# ---------------------------------------------------------------------------
# MREG-03: autoresearch-deregister.sh and remove command
# ---------------------------------------------------------------------------
echo ""
echo "=== MREG-03: Model deregistration ==="

test_deregister_syntax() {
  _assert_exit_zero "MREG-03 autoresearch-deregister.sh syntax valid" \
    bash -n "${SCRIPT_DIR}/autoresearch-deregister.sh"
}

test_litellm_register_remove() {
  # Create temp config with a model entry
  local tmp_config
  tmp_config=$(mktemp /tmp/litellm_config_XXXXXX.yaml)
  cat > "$tmp_config" << 'YAML'
model_list:
- model_name: test-model
  litellm_params:
    model: openai/test-model
    api_base: http://localhost:8021/v1
    api_key: none
litellm_settings:
  drop_params: true
YAML

  local tmp_script
  tmp_script=$(_make_patched_register "$tmp_config")

  local output
  output=$(python3 "$tmp_script" remove "test-model" 2>&1)
  local exit_code=$?
  rm -f "$tmp_script"

  if [ "$exit_code" -ne 0 ]; then
    _fail "MREG-03 _litellm_register.py remove exited non-zero: $output"
    rm -f "$tmp_config"
    return
  fi

  if ! grep -q "model_name: test-model" "$tmp_config"; then
    _pass "MREG-03 model entry removed from config"
  else
    _fail "MREG-03 model_name: test-model still present after remove"
  fi
  rm -f "$tmp_config"
}

test_deregister_not_found() {
  # Create minimal config with no matching model
  local tmp_config
  tmp_config=$(mktemp /tmp/litellm_config_XXXXXX.yaml)
  cat > "$tmp_config" << 'YAML'
model_list: []
litellm_settings:
  drop_params: true
YAML

  local tmp_script
  tmp_script=$(_make_patched_register "$tmp_config")

  local tmp_out exit_code output
  tmp_out=$(mktemp)
  set +e
  python3 "$tmp_script" remove "nonexistent-model" >"$tmp_out" 2>&1
  exit_code=$?
  set -e
  output=$(cat "$tmp_out")
  rm -f "$tmp_script" "$tmp_config" "$tmp_out"

  if [ "$exit_code" -eq 0 ]; then
    _fail "MREG-03 remove nonexistent model should exit non-zero (got 0)"
  else
    _pass "MREG-03 remove nonexistent model exits non-zero"
  fi
  _assert_contains "MREG-03 output says not found" "not found" "$output"
}

test_deregister_syntax
test_litellm_register_remove
test_deregister_not_found

# Cleanup shared test config from MREG-01/02
if [ -n "${_MREG_TEST_CONFIG:-}" ] && [ -f "${_MREG_TEST_CONFIG}" ]; then
  rm -f "${_MREG_TEST_CONFIG}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TOTAL=$((PASS + FAIL))
echo ""
echo "==================================="
echo "PASS: ${PASS} / TOTAL: ${TOTAL}"
echo "==================================="

if [ "${#ERRORS[@]}" -gt 0 ]; then
  echo ""
  echo "Failures:"
  for err in "${ERRORS[@]}"; do
    echo "  $err"
  done
  exit 1
fi
