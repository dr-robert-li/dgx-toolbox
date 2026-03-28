#!/usr/bin/env bash
# Shared library for DGX Toolbox launcher scripts
# Source this at the top of any launcher: source "$(dirname "$0")/lib.sh"

# Get the LAN IP address
get_ip() {
  hostname -I | awk '{print $1}'
}

# Check if a container is currently running
# Usage: is_running <container_name>
is_running() {
  docker ps --format '{{.Names}}' | grep -q "^${1}$"
}

# Check if a container exists (running or stopped)
# Usage: container_exists <container_name>
container_exists() {
  docker ps -a --format '{{.Names}}' | grep -q "^${1}$"
}

# Ensure a persistent container is running (start if stopped, create if missing)
# Returns 0 if container was already running, 1 if started/created
# Usage: ensure_container <container_name> <create_callback>
# The create_callback is called only if the container doesn't exist at all
ensure_container() {
  local name="$1"
  local create_fn="$2"

  if is_running "$name"; then
    echo "${name} is already running"
    return 0
  fi

  if container_exists "$name"; then
    echo "Starting existing ${name} container..."
    docker start "$name"
    return 1
  fi

  echo "Creating ${name} container..."
  $create_fn
  return 1
}

# Print a service banner with URLs
# Usage: print_banner <service_name> <port> [extra_lines...]
print_banner() {
  local name="$1"
  local port="$2"
  shift 2
  local ip
  ip=$(get_ip)

  echo ""
  echo "========================================"
  echo " ${name}"
  echo " Local:  http://localhost:${port}"
  echo " LAN:    http://${ip}:${port}"
  # Print any extra lines
  while [ $# -gt 0 ]; do
    echo " $1"
    shift
  done
  echo "========================================"
}

# Print Sync-friendly footer and stream logs
# Usage: stream_logs <container_name>
stream_logs() {
  echo ""
  echo "If using NVIDIA Sync, access via your forwarded local port."
  echo "Press Ctrl+C to stop watching logs (container keeps running)."
  echo ""
  docker logs -f "$1"
}

# Sync-mode exit: print status and return immediately (no log streaming)
# Usage: sync_exit <container_name> <port>
sync_exit() {
  echo "${1} starting on port ${2}"
  echo "Stream logs with: docker logs -f ${1}"
}

# Create host directories if they don't exist
# Usage: ensure_dirs ~/dir1 ~/dir2 ~/dir3
ensure_dirs() {
  mkdir -p "$@"
}

# Build extra -v flags from EXTRA_MOUNTS env var
# Format: EXTRA_MOUNTS="/host/a:/container/a,/host/b:/container/b"
# Comma-separated mount specs, each spec is host_path:container_path
# Invalid specs (no colon, empty segments) are skipped with warning to stderr
# Returns: string of "-v /host/a:/container/a -v /host/b:/container/b" or empty
build_extra_mounts() {
  [ -z "${EXTRA_MOUNTS:-}" ] && return 0
  local mounts=()
  local IFS=','
  for spec in $EXTRA_MOUNTS; do
    # Reset IFS for subshell trim
    spec=$(IFS=' ' ; echo "$spec" | xargs)  # trim whitespace
    if [[ "$spec" != *:* ]] || [[ -z "${spec%%:*}" ]] || [[ -z "${spec#*:}" ]]; then
      echo "Warning: skipping invalid mount spec: '$spec'" >&2
      continue
    fi
    mounts+=("-v" "$spec")
  done
  IFS=' ' ; echo "${mounts[*]}"
}
