#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_dgx_sparkrun_wrappers.sh
. "$SCRIPT_DIR/_dgx_sparkrun_wrappers.sh"

host_args=()
_dgx_collect_host_args host_args "$@"

exec sparkrun show "${host_args[@]}" "$@"
