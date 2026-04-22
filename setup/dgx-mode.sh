#!/usr/bin/env bash
# dgx-mode — switch dgx-toolbox between single-node and cluster mode.
#
# Writes ~/.config/dgx-toolbox/mode.env (consulted by aliases + setup scripts).
# Idempotent — safe to run repeatedly.
#
# Usage:
#   dgx-mode single
#   dgx-mode cluster <host1,host2,...> [--name <cluster-name>] [--user <ssh-user>]
#   dgx-mode status
#
# Precedence when launching workloads:
#   CLI flag (--cluster/--hosts/--solo)  >  DGX_MODE env var  >  mode.env  >  sparkrun default
#
# Sparkrun is the source of truth for cluster membership. This script only
# manages the dgx-toolbox mode marker and calls through to `sparkrun cluster`.
set -euo pipefail

CONFIG_DIR="${DGX_TOOLBOX_CONFIG_DIR:-$HOME/.config/dgx-toolbox}"
MODE_FILE="$CONFIG_DIR/mode.env"
DEFAULT_CLUSTER_NAME="dgx-default"
# Single-node mode registers this cluster (hosts=localhost) as sparkrun's
# default so `sparkrun run <recipe>` works without --hosts.
SOLO_CLUSTER_NAME="solo"
SOLO_CLUSTER_HOST="localhost"

mkdir -p "$CONFIG_DIR"

_write_mode() {
    # $1 = single|cluster, $2 = cluster name (optional)
    local mode="$1" cluster_name="${2:-}"
    {
        echo "# Managed by dgx-toolbox setup/dgx-mode.sh — edit via 'dgx-mode' CLI"
        echo "DGX_MODE=${mode}"
        [ -n "$cluster_name" ] && echo "DGX_DEFAULT_CLUSTER=${cluster_name}"
    } > "$MODE_FILE"
}

_require_sparkrun() {
    if ! command -v sparkrun >/dev/null 2>&1; then
        echo "ERROR: sparkrun not on PATH. Run setup/dgx-global-base-setup.sh first." >&2
        exit 1
    fi
}

cmd_single() {
    _require_sparkrun
    # Register (or update) a local-only cluster pointed at localhost and set
    # it as sparkrun's default. sparkrun's `run` command resolves hosts before
    # loading the recipe and exits if none are configured, so single-node
    # users MUST have a default cluster registered for bare `sparkrun run
    # <recipe>` and for the `vllm` wrapper to work.
    if sparkrun cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$SOLO_CLUSTER_NAME"; then
        echo "Updating solo cluster: $SOLO_CLUSTER_NAME -> $SOLO_CLUSTER_HOST (default)"
        sparkrun cluster update "$SOLO_CLUSTER_NAME" --hosts "$SOLO_CLUSTER_HOST" >/dev/null
        sparkrun cluster set-default "$SOLO_CLUSTER_NAME" >/dev/null
    else
        echo "Creating solo cluster: $SOLO_CLUSTER_NAME -> $SOLO_CLUSTER_HOST (default)"
        sparkrun cluster create "$SOLO_CLUSTER_NAME" \
            --hosts "$SOLO_CLUSTER_HOST" \
            --default \
            -d "Single-node mode — managed by dgx-toolbox dgx-mode" >/dev/null
    fi
    _write_mode single "$SOLO_CLUSTER_NAME"
    echo "Mode → single-node"
    echo "  Cluster:  $SOLO_CLUSTER_NAME ($SOLO_CLUSTER_HOST, default)"
    echo "  mode.env: $MODE_FILE"
}

cmd_cluster() {
    _require_sparkrun
    local hosts="${1:-}"
    shift || true
    local cluster_name="$DEFAULT_CLUSTER_NAME"
    local ssh_user=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --name) cluster_name="$2"; shift 2 ;;
            --user) ssh_user="$2"; shift 2 ;;
            *) echo "Unknown option: $1" >&2; exit 2 ;;
        esac
    done

    if [ -z "$hosts" ]; then
        echo "Usage: dgx-mode cluster <host1,host2,...> [--name NAME] [--user USER]" >&2
        exit 2
    fi

    # Create or update the cluster, set as default.
    if sparkrun cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$cluster_name"; then
        echo "Updating existing cluster: $cluster_name"
        local update_args=(--hosts "$hosts" --default)
        [ -n "$ssh_user" ] && update_args+=(--user "$ssh_user")
        sparkrun cluster update "$cluster_name" "${update_args[@]}"
    else
        echo "Creating cluster: $cluster_name"
        local create_args=(--hosts "$hosts" --default -d "Managed by dgx-toolbox dgx-mode")
        [ -n "$ssh_user" ] && create_args+=(--user "$ssh_user")
        sparkrun cluster create "$cluster_name" "${create_args[@]}"
    fi

    _write_mode cluster "$cluster_name"
    echo "Mode → cluster ($cluster_name)"
    echo "  Hosts:    $hosts"
    echo "  mode.env: $MODE_FILE"
}

cmd_status() {
    echo "dgx-toolbox mode status"
    echo "  Config:   $MODE_FILE"
    if [ -f "$MODE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$MODE_FILE"
        echo "  Mode:     ${DGX_MODE:-unset}"
        [ -n "${DGX_DEFAULT_CLUSTER:-}" ] && echo "  Cluster:  $DGX_DEFAULT_CLUSTER"
    else
        echo "  Mode:     unset (first-time setup not yet run)"
    fi
    echo ""
    if command -v sparkrun >/dev/null 2>&1; then
        echo "  sparkrun: $(sparkrun --version 2>/dev/null || echo 'unknown')"
        echo ""
        echo "  sparkrun clusters:"
        sparkrun cluster list 2>/dev/null | sed 's/^/    /' || echo "    (none)"
    else
        echo "  sparkrun: NOT INSTALLED (run setup/dgx-global-base-setup.sh)"
    fi
}

main() {
    local cmd="${1:-status}"
    shift || true
    case "$cmd" in
        single)   cmd_single "$@" ;;
        cluster)  cmd_cluster "$@" ;;
        status)   cmd_status "$@" ;;
        -h|--help|help)
            sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
            ;;
        *)
            echo "Unknown subcommand: $cmd" >&2
            echo "Try: dgx-mode single | dgx-mode cluster <hosts> | dgx-mode status" >&2
            exit 2
            ;;
    esac
}

main "$@"
