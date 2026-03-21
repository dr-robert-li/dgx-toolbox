#!/usr/bin/env bash
# modelstore/lib/notify.sh — Desktop notification helper with DBUS injection
# Provides notify_user() for sending desktop notifications from cron context.
# Falls back to ~/.modelstore/alerts.log when no desktop session is available.
# Sourced by disk_check_cron.sh — no set -e (caller controls).

# ---------------------------------------------------------------------------
# notify_user <summary> <body>
#
# Attempts to send a desktop notification via notify-send with DBUS injection.
# If notify-send fails (no desktop session, e.g. from cron), appends a
# timestamped message to ~/.modelstore/alerts.log instead.
#
# Parameters:
#   summary — short notification title (e.g. "modelstore: disk warning")
#   body    — longer message body
# ---------------------------------------------------------------------------
notify_user() {
  local summary="$1"
  local body="$2"

  # Get current user UID for DBUS discovery
  local uid
  uid=$(id -u)

  local dbus_addr=""

  # Primary: find DBUS_SESSION_BUS_ADDRESS from running gnome-session process
  local gnome_pid
  gnome_pid=$(pgrep -u "$uid" gnome-session 2>/dev/null | head -1)
  if [[ -n "$gnome_pid" ]]; then
    dbus_addr=$(grep -z DBUS_SESSION_BUS_ADDRESS \
      "/proc/${gnome_pid}/environ" 2>/dev/null \
      | tr -d '\0' \
      | sed 's/DBUS_SESSION_BUS_ADDRESS=//')
  fi

  # Fallback: systemd user bus socket (always present on Ubuntu 22+)
  if [[ -z "$dbus_addr" ]]; then
    dbus_addr="unix:path=/run/user/${uid}/bus"
  fi

  # Attempt desktop notification via notify-send with injected session env
  if DISPLAY=":0" \
     XDG_RUNTIME_DIR="/run/user/${uid}" \
     DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
     notify-send --app-name="modelstore" "$summary" "$body" 2>/dev/null; then
    return 0
  fi

  # Fallback: write to alerts.log when desktop session unavailable
  mkdir -p "${HOME}/.modelstore"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $summary -- $body" \
    >> "${HOME}/.modelstore/alerts.log"
}
