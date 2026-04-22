#!/usr/bin/env bash
# test-sparkrun-integration.sh (Simplified Integration Suite)
# ----------------------------------------------------------------------------
# Validates that DGX Toolbox correctly wraps sparkrun for single-node safety,
# recipe resolution, and auto-registration.
# ----------------------------------------------------------------------------
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0
FAILURES=()

pass() { PASS=$((PASS + 1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }
section() { printf "\n\033[1m== %s ==\033[0m\n" "$1"; }

# Setup a clean environment for each test
setup_test_env() {
  export DGX_TOOLBOX_CONFIG_DIR=$(mktemp -d)
  export STUB_DIR=$(mktemp -d)
  export STUB_LOG="$STUB_DIR/calls.log"
  
  cat > "$STUB_DIR/sparkrun" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$STUB_LOG"
# Emulate healthy status for watchdog tests if needed
if [[ "\$*" == *"proxy status"* ]]; then
  echo '{"running": true, "port": 4000}'
fi
EOF
  chmod +x "$STUB_DIR/sparkrun"
  export PATH="$STUB_DIR:$PATH"
}

cleanup_test_env() {
  rm -rf "${DGX_TOOLBOX_CONFIG_DIR:-/tmp/null}" "${STUB_DIR:-/tmp/null}"
}

# ---------------------------------------------------------------------------
section "1. Structural Integrity"
# ---------------------------------------------------------------------------
[ -f .sparkrun-pin ] && pass "Submodule pin present" || fail "Missing .sparkrun-pin"
[ -f scripts/_dgx_sparkrun_wrappers.sh ] && pass "Wrapper library present" || fail "Missing wrapper library"

# ---------------------------------------------------------------------------
section "2. Wrapper Logic (Host Injection & Defaults)"
# ---------------------------------------------------------------------------

# Test vllm: resolve local recipe + inject --hosts localhost in single mode
setup_test_env
export DGX_MODE=single
mkdir -p recipes
touch recipes/test-recipe.yaml
./scripts/vllm.sh test-recipe >/dev/null 2>&1
if grep -q "run $ROOT/recipes/test-recipe.yaml --hosts localhost" "$STUB_LOG"; then
  pass "vllm: resolves local recipe and injects --hosts localhost"
else
  fail "vllm: failed host injection or recipe resolution (got: $(cat "$STUB_LOG" 2>/dev/null))"
fi
cleanup_test_env

# Test vllm-stop: default to --all + inject --hosts localhost
setup_test_env
export DGX_MODE=single
./scripts/vllm-stop.sh >/dev/null 2>&1
if grep -q "stop --hosts localhost --all" "$STUB_LOG"; then
  pass "vllm-stop: defaults to --all and injects host"
else
  fail "vllm-stop: failed defaults or host injection (got: $(cat "$STUB_LOG" 2>/dev/null))"
fi
cleanup_test_env

# Test litellm-models: default to --refresh, NO host injection
setup_test_env
export DGX_MODE=single
./scripts/litellm-models.sh >/dev/null 2>&1
if grep -q "proxy models --refresh" "$STUB_LOG" && ! grep -q "\-\-hosts" "$STUB_LOG"; then
  pass "litellm-models: defaults to --refresh without host injection"
else
  fail "litellm-models: incorrect flags (got: $(cat "$STUB_LOG" 2>/dev/null))"
fi
cleanup_test_env

# ---------------------------------------------------------------------------
section "3. Auto-registration Watchdog Triggering"
# ---------------------------------------------------------------------------

# Test: Watchdog should NOT spawn if DGX_PROXY_AUTOREGISTER=0
setup_test_env
export DGX_MODE=single
export DGX_PROXY_AUTOREGISTER=0
# Mock _dgx_vllm_autoregister_watchdog to see if it's called
# We'll use a unique log for the watchdog itself
export WATCHDOG_LOG="$STUB_DIR/watchdog.log"
sed -i 's|_dgx_vllm_autoregister_watchdog|echo "WATCHDOG_STARTED" >> "$WATCHDOG_LOG"|g' scripts/vllm.sh

./scripts/vllm.sh some-recipe >/dev/null 2>&1
if [ ! -f "$WATCHDOG_LOG" ]; then
  pass "Autoregister: suppressed by DGX_PROXY_AUTOREGISTER=0"
else
  fail "Autoregister: watchdog started despite being disabled"
fi
git checkout scripts/vllm.sh # Restore script
cleanup_test_env

# ---------------------------------------------------------------------------
section "4. Alias & Environment Coherence"
# ---------------------------------------------------------------------------

# Verify that aliases in example.bash_aliases point to correct script paths
if grep -q "alias vllm='~/dgx-toolbox/scripts/vllm.sh'" example.bash_aliases; then
  pass "Aliases: vllm correctly defined"
else
  fail "Aliases: vllm definition missing or incorrect"
fi

# Ensure dgx-mode correctly configures the environment
setup_test_env
./setup/dgx-mode.sh single >/dev/null 2>&1
if grep -q "DGX_MODE=single" "$DGX_TOOLBOX_CONFIG_DIR/mode.env"; then
  pass "dgx-mode: correctly sets single mode in mode.env"
else
  fail "dgx-mode: failed to update mode.env"
fi
cleanup_test_env

# ---------------------------------------------------------------------------
section "Summary"
# ---------------------------------------------------------------------------
printf "\n  Passed: %d\n  Failed: %d\n" "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
