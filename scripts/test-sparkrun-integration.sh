#!/usr/bin/env bash
# test-sparkrun-integration.sh
# ----------------------------------------------------------------------------
# Smoke-test suite for the sparkrun integration. This does NOT exercise live
# GPUs, network, or Docker — it is a static/structural check that the
# integration is wired up correctly and can run in CI on plain Ubuntu.
#
# Run locally:
#   bash scripts/test-sparkrun-integration.sh
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed
# ----------------------------------------------------------------------------
set -u  # intentionally NOT set -e: we want to report all failures.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0
FAILURES=()

pass() { PASS=$((PASS + 1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }
section() { printf "\n\033[1m== %s ==\033[0m\n" "$1"; }

# ---------------------------------------------------------------------------
section "1. Submodule + pin"
# ---------------------------------------------------------------------------
if [ -f .gitmodules ] && grep -q "vendor/sparkrun" .gitmodules; then
  pass ".gitmodules declares vendor/sparkrun"
else
  fail ".gitmodules is missing a vendor/sparkrun entry"
fi

if [ -f .sparkrun-pin ]; then
  PIN=$(tr -d ' \t\n' < .sparkrun-pin)
  if [[ "$PIN" =~ ^[0-9a-f]{40}$ ]]; then
    pass ".sparkrun-pin contains a 40-char SHA ($PIN)"
  else
    fail ".sparkrun-pin is not a 40-char hex SHA"
  fi
else
  fail ".sparkrun-pin is missing"
fi

if [ -d vendor/sparkrun ]; then
  pass "vendor/sparkrun directory present"
  if [ -d vendor/sparkrun/.git ] || [ -f vendor/sparkrun/.git ]; then
    pass "vendor/sparkrun is a git submodule"
  else
    # In CI a fresh checkout without --recurse-submodules produces an empty dir.
    if [ -z "$(ls -A vendor/sparkrun 2>/dev/null)" ]; then
      fail "vendor/sparkrun is empty — run: git submodule update --init --recursive"
    else
      pass "vendor/sparkrun has content (already initialised)"
    fi
  fi
else
  fail "vendor/sparkrun directory missing"
fi

# ---------------------------------------------------------------------------
section "2. Recipes"
# ---------------------------------------------------------------------------
for recipe in recipes/nemotron-3-nano-4b-bf16-vllm.yaml recipes/eval-checkpoint.yaml; do
  if [ -f "$recipe" ]; then
    pass "$recipe exists"
    # Basic schema sanity.
    if grep -q '^recipe_version:[[:space:]]*"2"' "$recipe"; then
      pass "$recipe declares recipe_version \"2\""
    else
      fail "$recipe does not declare recipe_version \"2\""
    fi
    for key in model runtime container defaults; do
      if grep -q "^${key}:" "$recipe"; then
        :
      else
        fail "$recipe missing top-level key: $key"
      fi
    done
    # Python YAML parse if PyYAML is around.
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
      if python3 - "$recipe" <<'PY' >/dev/null 2>&1
import sys, yaml
with open(sys.argv[1]) as f:
    yaml.safe_load(f)
PY
      then
        pass "$recipe parses as valid YAML"
      else
        fail "$recipe failed YAML parse"
      fi
    fi
  else
    fail "$recipe missing"
  fi
done

# ---------------------------------------------------------------------------
section "3. Rewritten / removed scripts"
# ---------------------------------------------------------------------------
# Files that must be gone.
for gone in \
  inference/start-vllm.sh \
  inference/start-vllm-sync.sh \
  inference/start-litellm.sh \
  inference/start-litellm-sync.sh \
  inference/setup-litellm-config.sh \
  scripts/_litellm_register.py \
  scripts/test-eval-register.sh \
  example.vllm-model
do
  if [ -e "$gone" ]; then
    fail "$gone should have been removed but still exists"
  else
    pass "$gone is removed"
  fi
done

# Files that must exist and reference sparkrun.
declare -A MUST_REFERENCE=(
  [scripts/autoresearch-deregister.sh]="sparkrun proxy"
  [scripts/eval-checkpoint.sh]="sparkrun run"
  [scripts/demo-autoresearch.sh]="sparkrun"
  [scripts/claude-litellm.sh]="sparkrun proxy"
  [setup/dgx-global-base-setup.sh]="vendor/sparkrun"
  [setup/dgx-mode.sh]="mode.env"
  [setup/dgx-mode-picker.sh]="dgx-mode"
  [setup/dgx-recipes.sh]="sparkrun registry"
)

# Hugging Face onboarding wiring: dgx-global-base-setup.sh must install the
# `hf` CLI with hf_xet and export HF_XET_HIGH_PERFORMANCE=1 idempotently.
for needle in \
  'uv tool install --force --with hf_xet "huggingface_hub\[cli\]"' \
  'export HF_XET_HIGH_PERFORMANCE=1' \
  'hf auth login'
do
  if grep -qE "$needle" setup/dgx-global-base-setup.sh; then
    pass "dgx-global-base-setup.sh contains '$needle'"
  else
    fail "dgx-global-base-setup.sh missing '$needle'"
  fi
done
for file in "${!MUST_REFERENCE[@]}"; do
  if [ -f "$file" ]; then
    if grep -q "${MUST_REFERENCE[$file]}" "$file"; then
      pass "$file references '${MUST_REFERENCE[$file]}'"
    else
      fail "$file does not reference '${MUST_REFERENCE[$file]}'"
    fi
  else
    fail "$file is missing"
  fi
done

# Every .sh we own (excluding vendor/sparkrun and karpathy) must pass bash -n.
section "4. Bash syntax (bash -n)"
while IFS= read -r -d '' sh; do
  if bash -n "$sh" 2>/dev/null; then
    pass "bash -n $sh"
  else
    fail "bash -n $sh — syntax error"
  fi
done < <(find . -name '*.sh' \
  -not -path './.git/*' \
  -not -path './.claude/*' \
  -not -path './.codex/*' \
  -not -path './vendor/sparkrun/*' \
  -not -path './karpathy-autoresearch/*' \
  -print0)

# ---------------------------------------------------------------------------
section "5. Aliases + docker-compose"
# ---------------------------------------------------------------------------
if [ -f example.bash_aliases ]; then
  pass "example.bash_aliases present"
  for needle in \
    "alias vllm='~/dgx-toolbox/scripts/vllm.sh'" \
    "alias vllm-stop='~/dgx-toolbox/scripts/vllm-stop.sh'" \
    "alias vllm-logs='~/dgx-toolbox/scripts/vllm-logs.sh'" \
    "alias vllm-status='~/dgx-toolbox/scripts/vllm-status.sh'" \
    "alias vllm-show='~/dgx-toolbox/scripts/vllm-show.sh'" \
    "alias litellm='~/dgx-toolbox/scripts/litellm.sh'" \
    "alias litellm-models='~/dgx-toolbox/scripts/litellm-models.sh'" \
    "alias litellm-stop='sparkrun proxy stop'" \
    "alias claude-litellm='source ~/dgx-toolbox/scripts/claude-litellm.sh'" \
    "alias dgx-mode=" \
    "alias dgx-recipes=" \
    "alias dgx-discover="
  do
    if grep -Fq "$needle" example.bash_aliases; then
      pass "example.bash_aliases contains \"${needle}\""
    else
      fail "example.bash_aliases missing \"${needle}\""
    fi
  done
  # The old bare-alias form of vllm-stop/logs/status/show is the regression
  # we're guarding against — these must stay script-backed aliases, not
  # direct sparkrun passthroughs with no host-injection logic.
  for stale_alias in \
    "alias vllm-stop='sparkrun stop'" \
    "alias vllm-logs='sparkrun logs'" \
    "alias vllm-status='sparkrun status'" \
    "alias vllm-show='sparkrun show'"
  do
    if grep -Fq "$stale_alias" example.bash_aliases; then
      fail "example.bash_aliases still has bare alias \"${stale_alias}\" — should point at a wrapper script"
    else
      pass "example.bash_aliases no longer uses bare \"${stale_alias}\""
    fi
  done
else
  fail "example.bash_aliases missing"
fi

# Re-source safety: even if `vllm` is already an alias in the current shell,
# sourcing example.bash_aliases must cleanly replace it with the wrapper alias.
if bash -ic 'alias vllm="echo old"; source ./example.bash_aliases; alias vllm' 2>/dev/null | grep -q "scripts/vllm.sh"; then
  pass "example.bash_aliases re-sources cleanly over a pre-existing vllm alias"
else
  fail "example.bash_aliases fails to redefine vllm when an alias already exists"
fi

# Wrapper scripts must exist and be executable because the banner now relies
# on aliases that point directly at these paths.
for wrapper in \
  scripts/_dgx_sparkrun_wrappers.sh \
  scripts/vllm.sh \
  scripts/vllm-stop.sh \
  scripts/vllm-logs.sh \
  scripts/vllm-status.sh \
  scripts/vllm-show.sh \
  scripts/litellm.sh \
  scripts/litellm-models.sh
do
  if [ -x "$wrapper" ]; then
    pass "$wrapper is executable"
  else
    fail "$wrapper is missing or not executable"
  fi
done

# Single-node host injection: with DGX_MODE=single and no host flag from the
# caller, the vllm() wrapper must inject --hosts localhost so sparkrun's
# pre-recipe host check doesn't bail with "No hosts specified". Stub
# `sparkrun` as a function that echoes its argv, source the aliases, and
# check what gets forwarded.
# Existing tests set DGX_PROXY_AUTOREGISTER=0 so the autoregister watchdog
# doesn't run concurrently and pollute captured output. Autoregister has its
# own dedicated tests further down.
_SPARKRUN_STUB='sparkrun() { echo "STUB:$*"; }; export -f sparkrun'
OUT=$(bash -ic "$_SPARKRUN_STUB; export DGX_MODE=single DGX_PROXY_AUTOREGISTER=0; source ./example.bash_aliases; vllm qwen3.6" 2>/dev/null)
if echo "$OUT" | grep -q '^STUB:run ' && echo "$OUT" | grep -q 'qwen3.6' && echo "$OUT" | grep -q -- '--hosts localhost'; then
  pass "vllm() injects --hosts localhost in single mode when no host flag given"
else
  fail "vllm() did not inject --hosts localhost in single mode (got: $OUT)"
fi

# When the caller passes --hosts explicitly, the wrapper must NOT inject
# --hosts localhost on top (would duplicate the flag).
OUT=$(bash -ic "$_SPARKRUN_STUB; export DGX_MODE=single DGX_PROXY_AUTOREGISTER=0; source ./example.bash_aliases; vllm qwen3.6 --hosts 10.0.0.1" 2>/dev/null)
if echo "$OUT" | grep -q 'STUB:run qwen3.6 --hosts 10.0.0.1' && ! echo "$OUT" | grep -q -- '--hosts localhost'; then
  pass "vllm() skips host injection when caller passes --hosts explicitly"
else
  fail "vllm() wrongly injected host flag when caller already specified one (got: $OUT)"
fi

# When the caller passes --solo, the wrapper must also skip injection.
OUT=$(bash -ic "$_SPARKRUN_STUB; export DGX_MODE=single DGX_PROXY_AUTOREGISTER=0; source ./example.bash_aliases; vllm qwen3.6 --solo" 2>/dev/null)
if echo "$OUT" | grep -q 'STUB:run qwen3.6 --solo' && ! echo "$OUT" | grep -q -- '--hosts'; then
  pass "vllm() skips host injection when caller passes --solo"
else
  fail "vllm() wrongly injected --hosts when caller passed --solo (got: $OUT)"
fi

# When DGX_MODE is not set (fresh install, picker not run), the wrapper must
# NOT inject anything so we don't mask legitimate "no mode configured" errors.
OUT=$(bash -ic "$_SPARKRUN_STUB; unset DGX_MODE; export DGX_PROXY_AUTOREGISTER=0; export DGX_TOOLBOX_CONFIG_DIR=/nonexistent-$$; source ./example.bash_aliases; vllm qwen3.6" 2>/dev/null)
if echo "$OUT" | grep -q 'STUB:run qwen3.6' && ! echo "$OUT" | grep -q -- '--hosts'; then
  pass "vllm() does not inject --hosts when DGX_MODE is unset"
else
  fail "vllm() injected --hosts with no mode configured (got: $OUT)"
fi

# Autoregister: the watchdog function must call `sparkrun proxy status`, and
# when the proxy reports running:true, must then call `sparkrun proxy models
# --refresh`. We write the stub + driver to a temporary script file to keep
# case/newline handling intact across bash -c invocations.
AUTOREG_DIR=$(mktemp -d)
AUTOREG_LOG="$AUTOREG_DIR/calls.log"
export AUTOREG_LOG
cat > "$AUTOREG_DIR/stub-running.sh" <<'EOF_STUB'
sparkrun() {
  echo "CALL: $*" >> "$AUTOREG_LOG"
  case "$1 $2" in
    "proxy status") echo '{"running": true, "port": 4000}' ;;
    "proxy models") echo 'Synced proxy models: added 1.' ;;
    *) : ;;
  esac
}
export -f sparkrun
sleep() { :; }        # no-op to speed up the polling loop
export -f sleep
EOF_STUB
# Run watchdog directly so we don't race with backgrounding.
OUT=$(bash -c "source $AUTOREG_DIR/stub-running.sh && source ./scripts/_dgx_sparkrun_wrappers.sh && _dgx_vllm_autoregister_watchdog" 2>&1)
if echo "$OUT" | grep -q 'Registered new workload with LiteLLM proxy'; then
  pass "autoregister watchdog prints success message when proxy reports models added"
else
  fail "autoregister watchdog missed the success path (stderr: $OUT)"
fi
if grep -q 'CALL: proxy status --json' "$AUTOREG_LOG" && grep -q 'CALL: proxy models --hosts localhost --refresh' "$AUTOREG_LOG"; then
  pass "autoregister watchdog calls host-aware 'proxy models --refresh' after proxy status"
else
  fail "autoregister watchdog did not issue expected sparkrun calls (log: $(tr '\n' ';' < "$AUTOREG_LOG"))"
fi

# Autoregister skip: when the proxy is NOT running, the watchdog must loop
# without ever calling `proxy models --refresh`.
rm -f "$AUTOREG_LOG"
cat > "$AUTOREG_DIR/stub-stopped.sh" <<'EOF_STUB'
sparkrun() {
  echo "CALL: $*" >> "$AUTOREG_LOG"
  case "$1 $2" in
    "proxy status") echo '{"running": false}' ;;
    *) : ;;
  esac
}
export -f sparkrun
sleep() { :; }
export -f sleep
EOF_STUB
# If proxy stays stopped the watchdog loops all 240 iterations and returns 1.
# We only care that it does NOT call 'proxy models --refresh'.
timeout 5 bash -c "source $AUTOREG_DIR/stub-stopped.sh && source ./scripts/_dgx_sparkrun_wrappers.sh && _dgx_vllm_autoregister_watchdog" >/dev/null 2>&1 || true
if [ -s "$AUTOREG_LOG" ] && ! grep -q 'CALL: proxy models --refresh' "$AUTOREG_LOG"; then
  pass "autoregister watchdog does not call 'proxy models --refresh' when proxy is stopped"
else
  fail "autoregister watchdog wrongly called 'proxy models --refresh' with proxy stopped (log: $(tr '\n' ';' < "$AUTOREG_LOG" 2>/dev/null))"
fi

# Autoregister opt-out: DGX_PROXY_AUTOREGISTER=0 must prevent the wrapper
# from spawning the watchdog.
AUTOREG_LOG_OPT_OUT="$AUTOREG_DIR/opt-out.log"
cat > "$AUTOREG_DIR/stub-log-only.sh" <<EOF_STUB
sparkrun() { echo "CALL: \$*" >> "$AUTOREG_LOG_OPT_OUT"; }
export -f sparkrun
EOF_STUB
timeout 3 bash -ic "source $AUTOREG_DIR/stub-log-only.sh && export DGX_MODE=single DGX_PROXY_AUTOREGISTER=0 DGX_WATCHDOG_ATTEMPTS=1 DGX_WATCHDOG_SLEEP=0.1 && source ./example.bash_aliases && vllm qwen3.6" >/dev/null 2>&1 || true
sleep 0.2  # allow any backgrounded watchdog (there shouldn't be one) to flush
if grep -q 'CALL: run ' "$AUTOREG_LOG_OPT_OUT" 2>/dev/null && ! grep -q 'CALL: proxy status' "$AUTOREG_LOG_OPT_OUT" 2>/dev/null; then
  pass "DGX_PROXY_AUTOREGISTER=0 prevents autoregister watchdog from running"
else
  fail "DGX_PROXY_AUTOREGISTER=0 did not suppress autoregister (log: $(tr '\n' ';' < "$AUTOREG_LOG_OPT_OUT" 2>/dev/null))"
fi

# Autoregister skip on --dry-run: dry-run doesn't launch a workload.
AUTOREG_LOG_DRY_RUN="$AUTOREG_DIR/dry-run.log"
cat > "$AUTOREG_DIR/stub-log-dry.sh" <<EOF_STUB
sparkrun() { echo "CALL: \$*" >> "$AUTOREG_LOG_DRY_RUN"; }
export -f sparkrun
EOF_STUB
timeout 3 bash -ic "source $AUTOREG_DIR/stub-log-dry.sh && export DGX_MODE=single DGX_PROXY_AUTOREGISTER=1 DGX_WATCHDOG_ATTEMPTS=1 DGX_WATCHDOG_SLEEP=0.1 && source ./example.bash_aliases && vllm qwen3.6 --dry-run" >/dev/null 2>&1 || true
sleep 0.2
if grep -q 'CALL: run ' "$AUTOREG_LOG_DRY_RUN" 2>/dev/null && ! grep -q 'CALL: proxy status' "$AUTOREG_LOG_DRY_RUN" 2>/dev/null; then
  pass "--dry-run suppresses autoregister watchdog"
else
  fail "--dry-run did not suppress autoregister (log: $(tr '\n' ';' < "$AUTOREG_LOG_DRY_RUN" 2>/dev/null))"
fi

# Autoregister skip on --foreground: watchdog output would interleave with
# streamed container logs.
AUTOREG_LOG_FOREGROUND="$AUTOREG_DIR/foreground.log"
cat > "$AUTOREG_DIR/stub-log-fore.sh" <<EOF_STUB
sparkrun() { echo "CALL: \$*" >> "$AUTOREG_LOG_FOREGROUND"; }
export -f sparkrun
EOF_STUB
timeout 3 bash -ic "source $AUTOREG_DIR/stub-log-fore.sh && export DGX_MODE=single DGX_PROXY_AUTOREGISTER=1 DGX_WATCHDOG_ATTEMPTS=1 DGX_WATCHDOG_SLEEP=0.1 && source ./example.bash_aliases && vllm qwen3.6 --foreground" >/dev/null 2>&1 || true
sleep 0.2
if grep -q 'CALL: run ' "$AUTOREG_LOG_FOREGROUND" 2>/dev/null && ! grep -q 'CALL: proxy status' "$AUTOREG_LOG_FOREGROUND" 2>/dev/null; then
  pass "--foreground suppresses autoregister watchdog"
else
  fail "--foreground did not suppress autoregister (log: $(tr '\n' ';' < "$AUTOREG_LOG_FOREGROUND" 2>/dev/null))"
fi
rm -rf "$AUTOREG_DIR"
unset AUTOREG_LOG

# mode.env must persist a pre-existing DGX_PROXY_AUTOREGISTER=0 across
# re-runs of `dgx-mode single` so users don't lose their opt-out.
STUB_DIR2=$(mktemp -d)
cat > "$STUB_DIR2/sparkrun" <<'EOF_STUB'
#!/usr/bin/env bash
exit 0
EOF_STUB
chmod +x "$STUB_DIR2/sparkrun"
TMP_CFG2=$(mktemp -d)
# Seed mode.env with DGX_PROXY_AUTOREGISTER=0 (simulating a user who opted out)
cat > "$TMP_CFG2/mode.env" <<'EOF_MODE'
DGX_MODE=single
DGX_PROXY_AUTOREGISTER=0
EOF_MODE
PATH="$STUB_DIR2:$PATH" DGX_TOOLBOX_CONFIG_DIR="$TMP_CFG2" \
  bash setup/dgx-mode.sh single >/dev/null 2>&1
if grep -q 'DGX_PROXY_AUTOREGISTER=0' "$TMP_CFG2/mode.env" 2>/dev/null; then
  pass "dgx-mode single preserves existing DGX_PROXY_AUTOREGISTER=0 on re-run"
else
  fail "dgx-mode single clobbered DGX_PROXY_AUTOREGISTER=0 (mode.env: $(cat "$TMP_CFG2/mode.env" 2>/dev/null | tr '\n' ';'))"
fi
rm -rf "$STUB_DIR2" "$TMP_CFG2"

# ---------------------------------------------------------------------------
# vllm-stop / vllm-logs / vllm-status / vllm-show wrapper behavior.
# These used to be bare aliases ('sparkrun stop', 'sparkrun logs', ...). The
# bare form fails in single-node mode before a default cluster is registered
# because sparkrun's stop/logs paths call _resolve_hosts_or_exit() before
# the target check, producing "No hosts specified". The wrappers now live in
# standalone scripts that preserve the same host-injection logic, and
# vllm-stop still defaults to --all when no TARGET is supplied.

# vllm-stop with no args in single mode: inject --hosts localhost AND add --all
OUT=$(bash -ic "$_SPARKRUN_STUB; export DGX_MODE=single; source ./example.bash_aliases; vllm-stop" 2>/dev/null)
if echo "$OUT" | grep -q 'STUB:stop' && echo "$OUT" | grep -q -- '--hosts localhost' && echo "$OUT" | grep -q -- '--all'; then
  pass "vllm-stop with no args injects --hosts localhost and defaults to --all"
else
  fail "vllm-stop did not inject --hosts localhost + --all in single mode (got: $OUT)"
fi

# vllm-stop --all in single mode: inject host, do NOT duplicate --all.
OUT=$(bash -ic "$_SPARKRUN_STUB; export DGX_MODE=single; source ./example.bash_aliases; vllm-stop --all" 2>/dev/null)
ALL_COUNT=$(echo "$OUT" | grep -o -- '--all' | wc -l | tr -d ' ')
if echo "$OUT" | grep -q -- '--hosts localhost' && [ "$ALL_COUNT" = "1" ]; then
  pass "vllm-stop --all does not duplicate --all when caller supplies it"
else
  fail "vllm-stop --all duplicated or missed --all (got: $OUT, --all count=$ALL_COUNT)"
fi

# vllm-stop <target> in single mode: inject host, do NOT add --all (target
# and --all are mutually exclusive in sparkrun stop).
OUT=$(bash -ic "$_SPARKRUN_STUB; export DGX_MODE=single; source ./example.bash_aliases; vllm-stop my-recipe" 2>/dev/null)
if echo "$OUT" | grep -q -- '--hosts localhost' && echo "$OUT" | grep -q 'my-recipe' && ! echo "$OUT" | grep -q -- '--all'; then
  pass "vllm-stop <target> injects --hosts localhost and does not add --all"
else
  fail "vllm-stop <target> added --all or missed host injection (got: $OUT)"
fi

# vllm-stop with explicit --hosts: do NOT inject a second --hosts.
OUT=$(bash -ic "$_SPARKRUN_STUB; export DGX_MODE=single; source ./example.bash_aliases; vllm-stop --hosts 10.0.0.1 --all" 2>/dev/null)
HOST_COUNT=$(echo "$OUT" | grep -o -- '--hosts' | wc -l | tr -d ' ')
if [ "$HOST_COUNT" = "1" ] && echo "$OUT" | grep -q '10.0.0.1'; then
  pass "vllm-stop --hosts <x> does not duplicate --hosts when caller supplies it"
else
  fail "vllm-stop duplicated --hosts when caller supplied one (got: $OUT, --hosts count=$HOST_COUNT)"
fi

# vllm-stop with --cluster: skip host injection (cluster wins).
OUT=$(bash -ic "$_SPARKRUN_STUB; export DGX_MODE=single; source ./example.bash_aliases; vllm-stop --cluster prod --all" 2>/dev/null)
if echo "$OUT" | grep -q -- '--cluster prod' && ! echo "$OUT" | grep -q -- '--hosts'; then
  pass "vllm-stop --cluster skips --hosts injection"
else
  fail "vllm-stop --cluster wrongly injected --hosts (got: $OUT)"
fi

# vllm-stop with no DGX_MODE: no injection, still defaults to --all so
# "stop everything" works once the user configures a cluster.
OUT=$(bash -ic "$_SPARKRUN_STUB; unset DGX_MODE; export DGX_TOOLBOX_CONFIG_DIR=/nonexistent-$$; source ./example.bash_aliases; vllm-stop" 2>/dev/null)
if echo "$OUT" | grep -q 'STUB:stop --all' && ! echo "$OUT" | grep -q -- '--hosts'; then
  pass "vllm-stop with no mode configured defaults to --all and skips host injection"
else
  fail "vllm-stop with no mode behaved unexpectedly (got: $OUT)"
fi

# vllm-logs: inject --hosts localhost in single mode, pass positional args through.
OUT=$(bash -ic "$_SPARKRUN_STUB; export DGX_MODE=single; source ./example.bash_aliases; vllm-logs my-recipe --follow" 2>/dev/null)
if echo "$OUT" | grep -q 'STUB:logs' && echo "$OUT" | grep -q -- '--hosts localhost' && echo "$OUT" | grep -q 'my-recipe' && echo "$OUT" | grep -q -- '--follow'; then
  pass "vllm-logs injects --hosts localhost and forwards positional args + flags"
else
  fail "vllm-logs did not inject host or forward args (got: $OUT)"
fi

# vllm-status: inject --hosts localhost in single mode.
OUT=$(bash -ic "$_SPARKRUN_STUB; export DGX_MODE=single; source ./example.bash_aliases; vllm-status" 2>/dev/null)
if echo "$OUT" | grep -q 'STUB:status' && echo "$OUT" | grep -q -- '--hosts localhost'; then
  pass "vllm-status injects --hosts localhost in single mode"
else
  fail "vllm-status did not inject --hosts localhost (got: $OUT)"
fi

# litellm: inject --hosts localhost in single mode so proxy start's
# autodiscover loop can resolve the local workload. These are script-backed
# aliases, so stub sparkrun via PATH rather than a shell function.
PROXY_STUB_DIR=$(mktemp -d)
cat > "$PROXY_STUB_DIR/sparkrun" <<'EOF_STUB'
#!/usr/bin/env bash
echo "STUB:$*"
EOF_STUB
chmod +x "$PROXY_STUB_DIR/sparkrun"
OUT=$(PATH="$PROXY_STUB_DIR:$PATH" bash --noprofile --norc -c "shopt -s expand_aliases; export DGX_MODE=single; source ./example.bash_aliases; eval 'litellm --port 4001'" 2>/dev/null)
if echo "$OUT" | grep -q 'STUB:proxy start' && echo "$OUT" | grep -q -- '--hosts localhost' && echo "$OUT" | grep -q -- '--port 4001'; then
  pass "litellm injects --hosts localhost in single mode and forwards flags"
else
  fail "litellm did not inject --hosts localhost or forward flags (got: $OUT)"
fi

# litellm-models: inject --hosts localhost and default to --refresh.
OUT=$(PATH="$PROXY_STUB_DIR:$PATH" bash --noprofile --norc -c "shopt -s expand_aliases; export DGX_MODE=single; source ./example.bash_aliases; eval 'litellm-models --json'" 2>/dev/null)
REFRESH_COUNT=$(echo "$OUT" | grep -o -- '--refresh' | wc -l | tr -d ' ')
if echo "$OUT" | grep -q 'STUB:proxy models' && echo "$OUT" | grep -q -- '--hosts localhost' && [ "$REFRESH_COUNT" = "1" ] && echo "$OUT" | grep -q -- '--json'; then
  pass "litellm-models injects --hosts localhost and adds a single --refresh"
else
  fail "litellm-models did not inject host or default --refresh correctly (got: $OUT, --refresh count=$REFRESH_COUNT)"
fi

# litellm-models with explicit --refresh: don't duplicate it.
OUT=$(PATH="$PROXY_STUB_DIR:$PATH" bash --noprofile --norc -c "shopt -s expand_aliases; export DGX_MODE=single; source ./example.bash_aliases; eval 'litellm-models --refresh --json'" 2>/dev/null)
REFRESH_COUNT=$(echo "$OUT" | grep -o -- '--refresh' | wc -l | tr -d ' ')
if [ "$REFRESH_COUNT" = "1" ] && echo "$OUT" | grep -q -- '--hosts localhost'; then
  pass "litellm-models does not duplicate --refresh when caller supplies it"
else
  fail "litellm-models duplicated --refresh or missed host injection (got: $OUT, --refresh count=$REFRESH_COUNT)"
fi
rm -rf "$PROXY_STUB_DIR"

# vllm-show: inject --hosts localhost in single mode, forward recipe name.
OUT=$(bash -ic "$_SPARKRUN_STUB; export DGX_MODE=single; source ./example.bash_aliases; vllm-show recipe.yaml" 2>/dev/null)
if echo "$OUT" | grep -q 'STUB:show' && echo "$OUT" | grep -q -- '--hosts localhost' && echo "$OUT" | grep -q 'recipe.yaml'; then
  pass "vllm-show injects --hosts localhost and forwards recipe argument"
else
  fail "vllm-show did not inject host or forward argument (got: $OUT)"
fi

# The user-facing commands must now be aliases backed by wrapper scripts so
# the stock ~/.bashrc banner picks them up on shell refresh.
for fn in vllm-stop vllm-logs vllm-status vllm-show litellm litellm-models; do
  if bash --noprofile --norc -c "source ./example.bash_aliases; alias $fn 2>/dev/null" | grep -q "$fn="; then
    pass "$fn is an alias after sourcing example.bash_aliases"
  else
    fail "$fn is not an alias after sourcing example.bash_aliases"
  fi
done

# Re-source safety for the new wrappers: sourcing over pre-existing aliases
# (older installs) must replace them with the new wrapper aliases.
if bash --noprofile --norc -c 'alias vllm-stop="echo old"; alias vllm-logs="echo old"; alias vllm-status="echo old"; alias vllm-show="echo old"; alias litellm="echo old"; alias litellm-models="echo old"; source ./example.bash_aliases; alias litellm' 2>/dev/null | grep -q "scripts/litellm.sh"; then
  pass "example.bash_aliases re-sources cleanly over pre-existing proxy/vllm wrapper aliases"
else
  fail "example.bash_aliases fails to redefine wrappers when aliases already exist"
fi

# dgx-mode single must call through to sparkrun to register a localhost
# cluster as the default. Stub `sparkrun` and capture its calls to confirm.
STUB_DIR=$(mktemp -d)
cat > "$STUB_DIR/sparkrun" <<'EOF_STUB'
#!/usr/bin/env bash
echo "STUB_SPARKRUN $*" >> "$STUB_CALLS"
# emulate empty cluster list
if [ "$1" = "cluster" ] && [ "$2" = "list" ]; then exit 0; fi
exit 0
EOF_STUB
chmod +x "$STUB_DIR/sparkrun"
STUB_CALLS="$STUB_DIR/calls.log"
TMP_CFG=$(mktemp -d)
PATH="$STUB_DIR:$PATH" STUB_CALLS="$STUB_CALLS" DGX_TOOLBOX_CONFIG_DIR="$TMP_CFG" \
  bash setup/dgx-mode.sh single >/dev/null 2>&1
if grep -q 'cluster create solo --hosts localhost --default' "$STUB_CALLS" 2>/dev/null; then
  pass "dgx-mode single creates a 'solo' default cluster pointed at localhost"
else
  fail "dgx-mode single did not register solo/localhost cluster (calls: $(cat "$STUB_CALLS" 2>/dev/null | tr '\n' ';'))"
fi
if [ -f "$TMP_CFG/mode.env" ] && grep -q 'DGX_MODE=single' "$TMP_CFG/mode.env"; then
  pass "dgx-mode single writes DGX_MODE=single to mode.env"
else
  fail "dgx-mode single did not write DGX_MODE=single to mode.env"
fi
rm -rf "$STUB_DIR" "$TMP_CFG"

# dgx-discover script
if [ -x setup/dgx-discover.sh ]; then
  pass "setup/dgx-discover.sh is executable"
  if setup/dgx-discover.sh help >/dev/null 2>&1; then
    pass "setup/dgx-discover.sh help runs without error"
  else
    fail "setup/dgx-discover.sh help failed"
  fi
  if setup/dgx-discover.sh local >/dev/null 2>&1; then
    pass "setup/dgx-discover.sh local enumerates recipes/ directory"
  else
    fail "setup/dgx-discover.sh local failed"
  fi
else
  fail "setup/dgx-discover.sh missing or not executable"
fi

if [ -f docker-compose.inference.yml ]; then
  if grep -qE "^[[:space:]]*litellm:|^[[:space:]]*vllm:" docker-compose.inference.yml; then
    fail "docker-compose.inference.yml still declares litellm/vllm services"
  else
    pass "docker-compose.inference.yml no longer declares litellm/vllm services"
  fi
  if grep -q "open-webui:" docker-compose.inference.yml; then
    pass "docker-compose.inference.yml still declares open-webui"
  else
    fail "docker-compose.inference.yml is missing open-webui"
  fi
else
  fail "docker-compose.inference.yml missing"
fi

# ---------------------------------------------------------------------------
section "6. LICENSE / NOTICE / README / CHANGELOG"
# ---------------------------------------------------------------------------
if [ -f LICENSE ] && grep -q "MIT License" LICENSE; then
  pass "LICENSE is MIT"
else
  fail "LICENSE missing or not MIT"
fi

if [ -f NOTICE ] && grep -q "Apache License" NOTICE && grep -q "sparkrun" NOTICE; then
  pass "NOTICE attributes sparkrun under Apache-2.0"
else
  fail "NOTICE missing or missing Apache-2.0 sparkrun attribution"
fi

if grep -q "version-1\.5\.0" README.md; then
  pass "README.md carries the v1.5.0 badge"
else
  fail "README.md version badge not bumped to 1.5.0"
fi

if grep -q "vendor/sparkrun" README.md; then
  pass "README.md references vendor/sparkrun"
else
  fail "README.md has no reference to vendor/sparkrun"
fi

if grep -q "## 2026-04-22 .* sparkrun" CHANGELOG.md; then
  pass "CHANGELOG.md has the v1.5.0 sparkrun entry"
else
  fail "CHANGELOG.md missing v1.5.0 sparkrun entry"
fi

# ---------------------------------------------------------------------------
section "7. CI workflow"
# ---------------------------------------------------------------------------
if [ -f .github/workflows/test.yml ]; then
  if grep -q "submodules: true" .github/workflows/test.yml; then
    pass ".github/workflows/test.yml checks out submodules"
  else
    fail ".github/workflows/test.yml does not request submodules"
  fi
else
  fail ".github/workflows/test.yml missing"
fi

# ---------------------------------------------------------------------------
section "8. No stale LiteLLM/vLLM launchers referenced"
# ---------------------------------------------------------------------------
# Allowed: CHANGELOG.md (history) and this test script itself (checks for
# their removal, so it must name them). Fail anywhere else.
STALE=$(grep -rE "start-(vllm|litellm)(-sync)?\.sh|setup-litellm-config\.sh|_litellm_register\.py" \
  --include='*.sh' --include='*.py' --include='*.yml' --include='*.yaml' --include='*.md' \
  . 2>/dev/null \
  | grep -v '\.git/' \
  | grep -v '\.claude/' \
  | grep -v '\.codex/' \
  | grep -v '\.planning/' \
  | grep -v 'vendor/sparkrun/' \
  | grep -v 'CHANGELOG.md' \
  | grep -v 'scripts/test-sparkrun-integration.sh' \
  | grep -v 'README.md' \
  || true)
if [ -z "$STALE" ]; then
  pass "no runtime references to the deleted launcher scripts"
else
  fail "runtime references to deleted launcher scripts remain:"
  echo "$STALE" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
section "Summary"
# ---------------------------------------------------------------------------
printf "\n  Passed: %d\n  Failed: %d\n" "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  printf "\n  Failures:\n"
  for f in "${FAILURES[@]}"; do printf "    - %s\n" "$f"; done
  exit 1
fi
exit 0
