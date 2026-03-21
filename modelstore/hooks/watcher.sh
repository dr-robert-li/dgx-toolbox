#!/usr/bin/env bash
# modelstore/hooks/watcher.sh — Background usage tracking daemon
# Monitors docker events and filesystem access to update usage.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/config.sh"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

USAGE_FILE="${HOME}/.modelstore/usage.json"
USAGE_LOCK="${HOME}/.modelstore/usage.lock"
PIDFILE="${HOME}/.modelstore/watcher.pid"
DEBOUNCE_SECONDS=60

# ---------------------------------------------------------------------------
# Startup guards
# ---------------------------------------------------------------------------

# Exit silently if modelstore is not initialized
[[ -f "$MODELSTORE_CONFIG" ]] || exit 0  # Not initialized

# Single-instance guard via pidfile
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  exit 0
fi

# Write our PID
echo "$$" > "$PIDFILE"

# Cleanup trap: remove pidfile and kill child processes on exit
cleanup() {
  rm -f "$PIDFILE"
  kill "${DOCKER_PID:-}" "${INOTIFY_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Core function: ms_track_usage
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Helper: extract_model_id_from_path
# ---------------------------------------------------------------------------

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
# Function: watch_inotify
# ---------------------------------------------------------------------------

watch_inotify() {
  load_config
  local watch_paths=()
  [[ -d "$HOT_HF_PATH" ]]     && watch_paths+=("$HOT_HF_PATH")
  [[ -d "$HOT_OLLAMA_PATH" ]] && watch_paths+=("$HOT_OLLAMA_PATH")
  [[ ${#watch_paths[@]} -eq 0 ]] && { ms_log "No model directories to watch"; return 0; }

  inotifywait -m -r -e access,open \
    --exclude '\.lock$' \
    --format '%w%f' \
    "${watch_paths[@]}" 2>/dev/null \
  | while IFS= read -r accessed_path; do
      local model_path
      model_path=$(extract_model_id_from_path "$accessed_path") || continue
      [[ -n "$model_path" ]] && ms_track_usage "$model_path"
    done
}

# ---------------------------------------------------------------------------
# Function: extract_model_from_docker_event
# ---------------------------------------------------------------------------

extract_model_from_docker_event() {
  local event_json="$1"
  # Try to extract model from container command or environment
  # Best effort — docker event Actor.Attributes has limited info
  local image
  image=$(echo "$event_json" | jq -r '.Actor.Attributes.image // empty' 2>/dev/null)
  [[ -z "$image" ]] && return 1

  # For vLLM containers, try to get the model from container inspect
  local container_id
  container_id=$(echo "$event_json" | jq -r '.Actor.ID // empty' 2>/dev/null)
  [[ -z "$container_id" ]] && return 1

  # Inspect container for model path in args or env
  local cmd_args
  cmd_args=$(docker inspect --format '{{join .Args " "}}' "$container_id" 2>/dev/null) || return 1

  # Parse --model argument (vLLM pattern)
  local model_arg
  model_arg=$(echo "$cmd_args" | grep -oP '(?<=--model\s)\S+' 2>/dev/null) || true

  if [[ -n "$model_arg" && -d "$model_arg" ]]; then
    echo "$model_arg"
    return 0
  fi

  # Parse HF model binds
  local binds
  binds=$(docker inspect --format '{{range .Mounts}}{{.Source}} {{end}}' "$container_id" 2>/dev/null) || return 1
  for bind_path in $binds; do
    if [[ "$bind_path" == *models--* ]]; then
      echo "$bind_path"
      return 0
    fi
  done

  return 1
}

# ---------------------------------------------------------------------------
# Function: watch_docker_events
# ---------------------------------------------------------------------------

watch_docker_events() {
  # Skip if docker is not available
  command -v docker &>/dev/null || { ms_log "Docker not available, skipping container tracking"; return 0; }

  docker events --filter "event=start" --format '{{json .}}' 2>/dev/null \
  | while IFS= read -r event_json; do
      local model_path
      model_path=$(extract_model_from_docker_event "$event_json") || continue
      [[ -n "$model_path" ]] && ms_track_usage "$model_path"
    done
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------

# Load config for watch paths
load_config

ms_log "Watcher daemon starting (PID $$)"

# Start both watchers in background
watch_docker_events &
DOCKER_PID=$!

watch_inotify &
INOTIFY_PID=$!

# Wait for either to exit
wait -n 2>/dev/null || wait
ms_log "Watcher daemon exiting"
