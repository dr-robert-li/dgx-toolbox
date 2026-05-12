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

# Require host files to exist before mounting (fail-fast)
# Docker silently creates missing bind-mount sources as empty dirs, which
# breaks downstream commands like `pip -r <file>` or executing the mount.
# Usage: require_files ~/file1 ~/file2
require_files() {
  local missing=0
  for f in "$@"; do
    if [[ ! -f "$f" ]]; then
      echo "ERROR: required host file missing: $f" >&2
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || exit 1
}

# Pre-flight memory check (informational; never blocks launch)
# Warns to stderr if host MemAvailable or GPU memory.free is below threshold.
# Usage: memory_preflight [min_host_gb] [min_gpu_gb]
# Defaults: 16 GB host, 8 GB GPU. Override via MIN_HOST_GB / MIN_GPU_GB env.
memory_preflight() {
  local min_host="${MIN_HOST_GB:-${1:-16}}"
  local min_gpu="${MIN_GPU_GB:-${2:-8}}"

  local host_kb
  host_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)
  if [ -n "$host_kb" ]; then
    local host_gb=$((host_kb / 1024 / 1024))
    if [ "$host_gb" -lt "$min_host" ]; then
      echo "WARN: host MemAvailable=${host_gb}GB < ${min_host}GB; container may OOM (exit 137)" >&2
    fi
  fi

  if command -v nvidia-smi >/dev/null 2>&1; then
    local gpu_mib
    gpu_mib=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | awk 'NR==1{print $1}')
    # Skip if nvidia-smi returns [N/A] (e.g. DGX Spark unified-memory hosts).
    if [[ "$gpu_mib" =~ ^[0-9]+$ ]] && [ "$gpu_mib" -gt 0 ]; then
      local gpu_gb=$((gpu_mib / 1024))
      if [ "$gpu_gb" -lt "$min_gpu" ]; then
        echo "WARN: GPU memory.free=${gpu_gb}GB < ${min_gpu}GB; large-model loads may fail" >&2
      fi
    fi
  fi
}

# OOM banner — inspect a stopped container and surface OOM-vs-other-exit clearly
# Usage: oom_banner <container_name>
# Prints a banner and returns 0 when OOM/137 is detected; returns 1 otherwise.
oom_banner() {
  local name="$1"
  local oom exit_code
  oom=$(docker inspect "$name" -f '{{.State.OOMKilled}}' 2>/dev/null)
  exit_code=$(docker inspect "$name" -f '{{.State.ExitCode}}' 2>/dev/null)
  if [ "$oom" = "true" ] || [ "$exit_code" = "137" ]; then
    echo ""
    echo "================================================"
    echo "  Container OOM-killed (exit ${exit_code}, OOMKilled=${oom})"
    echo "================================================"
    echo "  Linux OOM killer or cgroup memory limit triggered."
    echo "  Recovery options:"
    echo "    - Reduce batch size / sequence length / model size"
    echo "    - Enable gradient checkpointing"
    echo "    - Use 4-bit quantisation (bitsandbytes)"
    echo "    - Free host RAM (close other workloads)"
    echo "    - Raise --shm-size or set --memory= on docker run"
    echo "================================================"
    return 0
  fi
  return 1
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
