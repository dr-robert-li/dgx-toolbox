#!/usr/bin/env bash
# modelstore/cron/migrate_cron.sh — Daily migration cron wrapper
# Prevents concurrent migrations via flock -n and delegates to cmd/migrate.sh.
# Called by crontab: 0 ${CRON_HOUR} * * * /path/to/cron/migrate_cron.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_FILE="${HOME}/.modelstore/migrate.lock"

# Acquire exclusive non-blocking lock — skip if migration already running
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[modelstore] Migration already running (lock held). Skipping." >&2
  exit 0
fi

# Delegate to cmd/migrate.sh with cron trigger marker
TRIGGER_SOURCE=cron exec "${SCRIPT_DIR}/../cmd/migrate.sh" "$@"
