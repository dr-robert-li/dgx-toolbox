#!/usr/bin/env bash
# First-time mode picker — invoked from setup/dgx-global-base-setup.sh.
# Non-interactive callers can set DGX_MODE=single|cluster and DGX_HOSTS=...
# to skip the prompt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${DGX_TOOLBOX_CONFIG_DIR:-$HOME/.config/dgx-toolbox}"
MODE_FILE="$CONFIG_DIR/mode.env"

# If already configured, noop. Re-run via `dgx-mode` to change.
if [ -f "$MODE_FILE" ] && [ "${DGX_MODE_PICKER_FORCE:-0}" != "1" ]; then
    echo "dgx-toolbox mode already configured at $MODE_FILE — skipping picker."
    echo "To change: dgx-mode single | dgx-mode cluster <hosts>"
    exit 0
fi

# Non-interactive path
if [ -n "${DGX_MODE:-}" ]; then
    case "$DGX_MODE" in
        single)
            "$SCRIPT_DIR/dgx-mode.sh" single
            exit 0
            ;;
        cluster)
            if [ -z "${DGX_HOSTS:-}" ]; then
                echo "DGX_MODE=cluster requires DGX_HOSTS=host1,host2,..." >&2
                exit 2
            fi
            "$SCRIPT_DIR/dgx-mode.sh" cluster "$DGX_HOSTS"
            exit 0
            ;;
        *)
            echo "Invalid DGX_MODE=$DGX_MODE (expected single|cluster)" >&2
            exit 2
            ;;
    esac
fi

# Interactive prompt
cat << 'EOF'

========================================
 dgx-toolbox — Inference mode setup
========================================

  [1] Single-node   (this DGX Spark only)            [default]
  [2] Cluster       (multi-DGX Spark over SSH mesh)

EOF

read -rp "Select mode [1]: " choice
choice="${choice:-1}"

case "$choice" in
    1)
        "$SCRIPT_DIR/dgx-mode.sh" single
        ;;
    2)
        read -rp "SSH-reachable hosts (comma-separated, e.g. 10.0.0.1,10.0.0.2): " hosts
        read -rp "Optional SSH user (leave blank for current user): " ssh_user
        if [ -n "$ssh_user" ]; then
            "$SCRIPT_DIR/dgx-mode.sh" cluster "$hosts" --user "$ssh_user"
        else
            "$SCRIPT_DIR/dgx-mode.sh" cluster "$hosts"
        fi
        cat << 'EOF'

Cluster mode selected. Before running multi-node workloads, finish SSH mesh
setup with:

  sparkrun setup ssh-mesh

See https://sparkrun.dev/getting-started/quick-start/ for full guidance.
EOF
        ;;
    *)
        echo "Invalid choice: $choice" >&2
        exit 2
        ;;
esac
