#!/bin/bash

# claude-litellm.sh
# A wrapper for 'claude' (Claude Code) that routes through the sparkrun
# proxy (LiteLLM, :4000). LiteLLM translates between the Anthropic Messages
# API and whatever backend the model is registered against, so this works
# for any model sparkrun has discovered — vLLM workloads, Ollama, remote
# providers, etc.
#
# Sets necessary environment variables for the session and reverts them
# upon exit. Pattern mirrors scripts/claude-ollama.sh so muscle memory
# carries over.

function claude_litellm() {
    # 1. Sanity-check sparkrun CLI availability
    if ! command -v sparkrun >/dev/null 2>&1; then
        echo "Error: 'sparkrun' command not found."
        echo "Install it via:  ~/dgx-toolbox/setup/dgx-global-base-setup.sh"
        return 1
    fi

    # 2. Ensure the proxy is running (LiteLLM listens on :4000)
    local proxy_port="${SPARKRUN_PROXY_PORT:-4000}"
    local proxy_host="${SPARKRUN_PROXY_HOST:-localhost}"
    local proxy_url="http://${proxy_host}:${proxy_port}"

    if ! curl -fsS --max-time 2 "${proxy_url}/health/liveliness" >/dev/null 2>&1 \
        && ! curl -fsS --max-time 2 "${proxy_url}/health" >/dev/null 2>&1; then
        echo "Error: sparkrun proxy is not reachable at ${proxy_url}."
        echo "Start it with:  sparkrun proxy start   (alias: litellm)"
        return 1
    fi

    # 3. Discover registered models (JSON output from sparkrun)
    local models_json
    if ! models_json=$(sparkrun proxy models --json 2>/dev/null); then
        echo "Error: 'sparkrun proxy models --json' failed."
        return 1
    fi

    local models=()
    while IFS= read -r name; do
        [ -n "$name" ] && models+=("$name")
    done < <(printf '%s' "$models_json" \
        | python3 -c 'import json,sys
try:
    for m in json.load(sys.stdin):
        n = m.get("model_name")
        if n:
            print(n)
except Exception:
    pass' 2>/dev/null)

    if [ "${#models[@]}" -eq 0 ]; then
        echo "No models registered with the sparkrun proxy."
        echo "Start a workload first, e.g.:  vllm nemotron-3-nano-4b-bf16-vllm"
        echo "Then refresh the proxy:        sparkrun proxy models --refresh"
        return 1
    fi

    # 4. Model selection (numbered list)
    echo "------------------------------------------------"
    echo "Models registered with sparkrun proxy (${proxy_url}):"
    local i=1
    for m in "${models[@]}"; do
        echo "$i) $m"
        i=$((i+1))
    done
    echo "------------------------------------------------"

    local choice
    local model_name=""
    while true; do
        read -r -p "Select a model (1-${#models[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#models[@]}" ]; then
            model_name="${models[$((choice-1))]}"
            break
        fi
        echo "Invalid selection."
    done

    echo "Selected: $model_name"

    # 5. Session tracking (global across shells)
    local session_file="/tmp/claude_litellm_sessions_$(id -u)"
    local count=0
    [ -f "$session_file" ] && count=$(cat "$session_file")

    if [ "$count" -gt 0 ]; then
        echo "Another LiteLLM-backed Claude Code session is already active (Total: $count)."
    fi

    # 6. Save current shell state for restoration
    local OLD_API_KEY="${ANTHROPIC_API_KEY-UNSET_MARKER}"
    local OLD_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN-UNSET_MARKER}"
    local OLD_BASE_URL="${ANTHROPIC_BASE_URL-UNSET_MARKER}"
    local OLD_MODEL="${ANTHROPIC_MODEL-UNSET_MARKER}"
    local OLD_HAIKU="${ANTHROPIC_DEFAULT_HAIKU_MODEL-UNSET_MARKER}"
    local OLD_SONNET="${ANTHROPIC_DEFAULT_SONNET_MODEL-UNSET_MARKER}"
    local OLD_OPUS="${ANTHROPIC_DEFAULT_OPUS_MODEL-UNSET_MARKER}"
    local OLD_SMALL_FAST="${ANTHROPIC_SMALL_FAST_MODEL-UNSET_MARKER}"
    local OLD_TELEMETRY="${DISABLE_TELEMETRY-UNSET_MARKER}"
    local OLD_TRAFFIC="${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC-UNSET_MARKER}"

    # 7. Suppress native Anthropic credentials; point Claude Code at the proxy
    echo "------------------------------------------------"
    echo "⚠️  Suppressing ALL native Anthropic credentials for LiteLLM session..."

    unset ANTHROPIC_AUTH_TOKEN
    unset ANTHROPIC_API_KEY

    export ANTHROPIC_BASE_URL="${proxy_url}"
    # sparkrun's default master_key is None (no auth) per
    # vendor/sparkrun/src/sparkrun/proxy/__init__.py, so any non-empty
    # token satisfies Claude Code's header requirement. If the operator
    # has set a master key via `sparkrun proxy start --master-key ...`,
    # they can export SPARKRUN_MASTER_KEY beforehand and this wrapper
    # will pick it up.
    export ANTHROPIC_AUTH_TOKEN="${SPARKRUN_MASTER_KEY:-sparkrun-local}"

    # Force every Claude Code tier to resolve to the selected local model.
    # Per LiteLLM's Claude Code tutorial, these env vars prevent Claude
    # from silently falling back to a cloud model.
    export ANTHROPIC_MODEL="$model_name"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$model_name"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$model_name"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$model_name"
    export ANTHROPIC_SMALL_FAST_MODEL="$model_name"

    export DISABLE_TELEMETRY=1
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

    echo "✅ Claude Code pointed at sparkrun proxy (${proxy_url})."
    echo "✅ All model tiers pinned to: $model_name"
    echo "------------------------------------------------"

    # 8. Increment session count
    echo $((count + 1)) > "$session_file"

    # 9. Preserve caller arguments
    local claude_args=("$@")

    # 10. Execute Claude Code
    echo "Launching Claude Code via LiteLLM with $model_name..."
    claude --model "$model_name" "${claude_args[@]}"

    # 11. Decrement / clean up session counter
    local current_count
    current_count=$(cat "$session_file" 2>/dev/null || echo 1)
    local new_count=$((current_count - 1))

    if [ "$new_count" -le 0 ]; then
        echo 0 > "$session_file"
        rm -f "$session_file"
        echo "------------------------------------------------"
        echo "Last LiteLLM session ended. Global environment cleanup complete."
    else
        echo "$new_count" > "$session_file"
        echo "------------------------------------------------"
        echo "Remaining active LiteLLM sessions: $new_count"
    fi

    # 12. Revert this shell's env vars
    revert_env() {
        local var_name=$1
        local old_val=$2
        if [ "$old_val" == "UNSET_MARKER" ]; then
            unset "$var_name"
        else
            export "$var_name"="$old_val"
        fi
    }

    revert_env ANTHROPIC_API_KEY "$OLD_API_KEY"
    revert_env ANTHROPIC_AUTH_TOKEN "$OLD_AUTH_TOKEN"
    revert_env ANTHROPIC_BASE_URL "$OLD_BASE_URL"
    revert_env ANTHROPIC_MODEL "$OLD_MODEL"
    revert_env ANTHROPIC_DEFAULT_HAIKU_MODEL "$OLD_HAIKU"
    revert_env ANTHROPIC_DEFAULT_SONNET_MODEL "$OLD_SONNET"
    revert_env ANTHROPIC_DEFAULT_OPUS_MODEL "$OLD_OPUS"
    revert_env ANTHROPIC_SMALL_FAST_MODEL "$OLD_SMALL_FAST"
    revert_env DISABLE_TELEMETRY "$OLD_TELEMETRY"
    revert_env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC "$OLD_TRAFFIC"

    echo "🔄 Original Anthropic credentials restored to shell."
    echo "------------------------------------------------"
}

# Run the function with all passed arguments
claude_litellm "$@"
