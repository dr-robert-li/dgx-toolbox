#!/bin/bash

# claude-ollama.sh
# A wrapper for 'claude' (Claude Code) to use local Ollama models.
# Sets necessary environment variables and reverts them upon exit.

function claude_ollama() {
    # 1. Check if ollama is available
    if ! command -v ollama >/dev/null 2>&1; then
        echo "Error: 'ollama' command not found. Please install Ollama."
        return 1
    fi

    # 2. Get available models
    local models=($(ollama list | tail -n +2 | awk '{print $1}'))
    if [ ${#models[@]} -eq 0 ]; then
        echo "No Ollama models found. Please pull a model first (e.g., 'ollama pull qwen2.5:latest')."
        return 1
    fi

    # 3. Model selection (Numbered list)
    echo "------------------------------------------------"
    echo "Available Ollama Models:"
    local i=1
    for m in "${models[@]}"; do
        echo "$i) $m"
        i=$((i+1))
    done
    echo "------------------------------------------------"

    local choice
    local model_name=""
    while true; do
        read -p "Select a model (1-${#models[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#models[@]}" ]; then
            model_name="${models[$((choice-1))]}"
            break
        fi
        echo "Invalid selection."
    done

    echo "Selected: $model_name"

    # 4. Session Tracking (Global across shells)
    local session_file="/tmp/claude_ollama_sessions_$(id -u)"
    local count=0
    [ -f "$session_file" ] && count=$(cat "$session_file")

    # 5. Check if another session is already commenced
    if [ "$count" -gt 0 ]; then
        echo "Another Ollama session is already active (Total: $count)."
    fi

    # 6. Save current shell state to local variables for restoration
    local OLD_API_KEY="${ANTHROPIC_API_KEY-UNSET_MARKER}"
    local OLD_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN-UNSET_MARKER}"
    local OLD_BASE_URL="${ANTHROPIC_BASE_URL-UNSET_MARKER}"
    local OLD_HAIKU="${ANTHROPIC_DEFAULT_HAIKU_MODEL-UNSET_MARKER}"
    local OLD_SONNET="${ANTHROPIC_DEFAULT_SONNET_MODEL-UNSET_MARKER}"
    local OLD_OPUS="${ANTHROPIC_DEFAULT_OPUS_MODEL-UNSET_MARKER}"
    local OLD_TELEMETRY="${DISABLE_TELEMETRY-UNSET_MARKER}"
    local OLD_TRAFFIC="${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC-UNSET_MARKER}"

    # 7. Suppress Anthropic auth for the Ollama-backed session only
    echo "------------------------------------------------"
    echo "⚠️  Suppressing ALL native Anthropic credentials for Ollama session..."
    
    # Clear both first so the wrapper controls exactly what Claude sees.
    unset ANTHROPIC_AUTH_TOKEN
    unset ANTHROPIC_API_KEY
    
    # Claude Code should target the local Ollama API root for this session.
    export ANTHROPIC_BASE_URL="http://localhost:11434"
    # Current Claude Code accepts the Ollama local-provider flow via AUTH_TOKEN.
    export ANTHROPIC_AUTH_TOKEN="ollama"
    
    # Force use of local model for all tiers to prevent fallback to cloud
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$model_name"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$model_name"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$model_name"
    
    export DISABLE_TELEMETRY=1
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    
    echo "✅ Official Ollama environment variables applied."
    echo "------------------------------------------------"

    # Increment session count
    echo $((count + 1)) > "$session_file"

    # 8. Preserve all user arguments when invoking Claude Code.
    local claude_args=("$@")

    # 9. Execute Claude Code
    echo "Launching Claude Code with $model_name..."
    claude --model "$model_name" "${claude_args[@]}"

    # 10. Restoration Logic
    local current_count=$(cat "$session_file")
    local new_count=$((current_count - 1))
    
    if [ "$new_count" -le 0 ]; then
        echo 0 > "$session_file"
        rm -f "$session_file"
        echo "------------------------------------------------"
        echo "Last Ollama session ended. Global environment cleanup complete."
    else
        echo "$new_count" > "$session_file"
        echo "------------------------------------------------"
        echo "Remaining active Ollama sessions: $new_count"
    fi

    # 11. Revert environment variables for THIS shell session
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
    revert_env ANTHROPIC_DEFAULT_HAIKU_MODEL "$OLD_HAIKU"
    revert_env ANTHROPIC_DEFAULT_SONNET_MODEL "$OLD_SONNET"
    revert_env ANTHROPIC_DEFAULT_OPUS_MODEL "$OLD_OPUS"
    revert_env DISABLE_TELEMETRY "$OLD_TELEMETRY"
    revert_env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC "$OLD_TRAFFIC"

    echo "🔄 Original Anthropic credentials restored to shell."
    echo "------------------------------------------------"
}

# Run the function with all passed arguments
claude_ollama "$@"
