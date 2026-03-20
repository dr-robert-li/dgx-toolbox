#!/usr/bin/env bash
# modelstore.sh — CLI entry point (thin router)
# Resolves subcommand and execs the appropriate cmd/ script.
set -euo pipefail

MODELSTORE_DIR="$(cd "$(dirname "$(readlink -f "$0")")/modelstore" && pwd)"
MODELSTORE_LIB="${MODELSTORE_DIR}/lib"
MODELSTORE_CMD="${MODELSTORE_DIR}/cmd"

# shellcheck source=modelstore/lib/common.sh
source "${MODELSTORE_LIB}/common.sh"
# shellcheck source=modelstore/lib/config.sh
source "${MODELSTORE_LIB}/config.sh"

SUBCOMMAND="${1:-help}"
shift 2>/dev/null || true

case "$SUBCOMMAND" in
  init)    exec "${MODELSTORE_CMD}/init.sh"    "$@" ;; # cmd/init.sh
  status)  exec "${MODELSTORE_CMD}/status.sh"  "$@" ;; # cmd/status.sh
  migrate) exec "${MODELSTORE_CMD}/migrate.sh" "$@" ;; # cmd/migrate.sh
  recall)  exec "${MODELSTORE_CMD}/recall.sh"  "$@" ;; # cmd/recall.sh
  revert)  exec "${MODELSTORE_CMD}/revert.sh"  "$@" ;; # cmd/revert.sh
  help|--help|-h)
    echo "Usage: modelstore <subcommand>"
    echo ""
    echo "Subcommands:"
    echo "  init     Interactive setup wizard"
    echo "  status   Show models by tier with sizes"
    echo "  migrate  Move stale models hot->cold"
    echo "  recall   Move model cold->hot"
    echo "  revert   Move all models back to hot, remove symlinks"
    echo ""
    echo "Run 'modelstore help' for this message."
    exit 0
    ;;
  *)
    echo "Unknown subcommand: ${SUBCOMMAND}" >&2
    echo "Run: modelstore help" >&2
    exit 1
    ;;
esac
