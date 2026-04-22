#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_dgx_sparkrun_wrappers.sh
. "$SCRIPT_DIR/_dgx_sparkrun_wrappers.sh"

host_args=()
_dgx_collect_host_args host_args "$@"

has_target=0
has_all=0
for arg in "$@"; do
  case "$arg" in
    --all|-a) has_all=1 ;;
    -*|--*=*) ;;
    *) has_target=1 ;;
  esac
done

extra_args=()
if [ "$has_target" -eq 0 ] && [ "$has_all" -eq 0 ]; then
  extra_args+=(--all)
fi

_dgx_exec_sparkrun stop "${host_args[@]}" "${extra_args[@]}" "$@"
