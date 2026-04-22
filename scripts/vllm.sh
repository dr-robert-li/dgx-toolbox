#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_dgx_sparkrun_wrappers.sh
. "$SCRIPT_DIR/_dgx_sparkrun_wrappers.sh"

if [ "$#" -lt 1 ]; then
  echo "Usage: vllm <recipe-name|path/to/recipe.yaml> [sparkrun run options...]" >&2
  exit 1
fi

recipe="$1"
shift
resolved_recipe="$(_dgx_vllm_resolve_recipe "$recipe")"

is_foreground=0
is_dry_run=0
for arg in "$@"; do
  case "$arg" in
    --foreground) is_foreground=1 ;;
    --dry-run) is_dry_run=1 ;;
  esac
done

host_args=()
_dgx_collect_host_args host_args "$@"

if _dgx_vllm_should_autoregister && [ "$is_foreground" -eq 0 ] && [ "$is_dry_run" -eq 0 ]; then
  ( _dgx_vllm_autoregister_watchdog ) >&2 &
  disown 2>/dev/null || true
fi

_dgx_exec_sparkrun run "$resolved_recipe" "${host_args[@]}" "$@"
