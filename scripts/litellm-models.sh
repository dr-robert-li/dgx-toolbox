#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_dgx_sparkrun_wrappers.sh
. "$SCRIPT_DIR/_dgx_sparkrun_wrappers.sh"

host_args=()
_dgx_collect_host_args host_args "$@"

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

exec sparkrun proxy models "${host_args[@]}" "${extra_args[@]}" "$@"
