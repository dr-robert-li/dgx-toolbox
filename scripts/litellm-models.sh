#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_dgx_sparkrun_wrappers.sh
. "$SCRIPT_DIR/_dgx_sparkrun_wrappers.sh"

has_refresh=0
for arg in "$@"; do
  case "$arg" in
    --refresh) has_refresh=1 ;;
  esac
done

extra_args=()
if [ "$has_refresh" -eq 0 ]; then
  extra_args+=(--refresh)
fi

_dgx_exec_sparkrun proxy models "${extra_args[@]}" "$@"
