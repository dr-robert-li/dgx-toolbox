#!/usr/bin/env bash
# modelstore/lib/common.sh — Shared safety and logging functions
# Sourced by modelstore.sh and all cmd/ scripts. No set -e (caller controls).

# shellcheck source=../../lib.sh
_TOOLBOX_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../" && pwd)/lib.sh"
source "$_TOOLBOX_LIB"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

# Log a message to stderr with [modelstore] prefix
ms_log() {
  echo "[modelstore] $*" >&2
}

# Log an error to stderr and exit with code 1
ms_die() {
  echo "[modelstore] ERROR: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Mount verification
# ---------------------------------------------------------------------------

# Verify that cold_path is an active mount point (not just a directory).
# Usage: check_cold_mounted <cold_path>
check_cold_mounted() {
  local cold_path="$1"
  mountpoint -q "$cold_path" || ms_die "Cold drive not mounted: $cold_path"
}

# ---------------------------------------------------------------------------
# Space check
# ---------------------------------------------------------------------------

# Check that destination_path has at least required_bytes available (with 10% margin).
# Usage: check_space <destination_path> <required_bytes>
# Returns 0 if sufficient space, 1 if insufficient.
check_space() {
  local dest="$1"
  local required_bytes="$2"
  local available
  available=$(df --output=avail -B1 "$dest" | tail -1)
  # Apply 10% safety margin: usable = available * 90 / 100
  local usable=$(( available * 90 / 100 ))
  if [[ "$usable" -lt "$required_bytes" ]]; then
    ms_log "Insufficient space at $dest: ${usable} bytes usable (need ${required_bytes})"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Filesystem validation
# ---------------------------------------------------------------------------

# Validate that cold_path is on a Linux filesystem that supports symlinks.
# Accepts: ext4, xfs, btrfs
# Rejects: exfat, vfat, ntfs (with clear error and reformatting hint)
# Unknown filesystems: warns but returns 0 (non-blocking)
# Usage: validate_cold_fs <cold_path>
# Returns 0 if acceptable, 1 if rejected.
validate_cold_fs() {
  local cold_path="$1"
  local fstype
  fstype=$(findmnt --output FSTYPE --target "$cold_path" --noheadings 2>/dev/null)
  if [[ -z "$fstype" ]]; then
    echo "[modelstore] ERROR: Cannot determine filesystem type for $cold_path" >&2
    echo "[modelstore] ERROR: Is the drive mounted at that path?" >&2
    return 1
  fi
  case "$fstype" in
    ext4|xfs|btrfs)
      return 0
      ;;
    exfat|vfat|ntfs)
      echo "[modelstore] ERROR: Cold drive filesystem is '$fstype' — symlinks are not supported." >&2
      echo "[modelstore] ERROR: Modelstore requires ext4, xfs, or btrfs for the cold drive." >&2
      echo "[modelstore] ERROR: To reformat (WARNING: destroys all data): sudo mkfs.ext4 /dev/sdX" >&2
      return 1
      ;;
    *)
      ms_log "WARNING: Unknown filesystem '$fstype' on $cold_path. Proceeding with caution."
      return 0
      ;;
  esac
}
