#!/usr/bin/env bash
# dgx-recipes — register and manage sparkrun recipe registries for dgx-toolbox.
#
# Idempotent. Safe to run repeatedly. Adds the default upstream registries
# (official + community, plus the local recipes/ directory) via
# `sparkrun registry add <URL>`, which reads each repo's .sparkrun/registry.yaml
# manifest and installs every registry declared there.
#
# Usage:
#   dgx-recipes add          # register default registries (default action)
#   dgx-recipes list         # list currently registered registries
#   dgx-recipes update       # git-pull every enabled registry; restore missing defaults
#   dgx-recipes status       # short summary
#
# Precedence: sparkrun's own registry state (stored under ~/.config/sparkrun/)
# remains the source of truth. This script is a thin convenience wrapper so
# dgx-toolbox setup can provision the defaults non-interactively and users can
# refresh them via one alias.
set -euo pipefail

# Default upstream registry URLs. Each repo ships a .sparkrun/registry.yaml
# manifest, so `sparkrun registry add <URL>` is all that's needed — sparkrun
# resolves the declared registry names, subpaths, and visibility from the
# manifest. Keeping this list explicit (rather than relying on sparkrun's
# internal fallbacks) means dgx-toolbox users get a deterministic, documented
# set even if sparkrun's defaults shift between releases.
DEFAULT_REGISTRY_URLS=(
    "https://github.com/spark-arena/recipe-registry"
    "https://github.com/spark-arena/community-recipe-registry"
)

_require_sparkrun() {
    if ! command -v sparkrun >/dev/null 2>&1; then
        echo "ERROR: sparkrun not on PATH. Run setup/dgx-global-base-setup.sh first." >&2
        exit 1
    fi
}

_registry_known() {
    # Returns 0 if a registry with the given URL (or URL.git variant) is
    # already registered. Compares against `sparkrun registry list` URLs,
    # tolerating trailing .git and trailing slashes.
    local want="$1"
    local norm_want="${want%.git}"
    norm_want="${norm_want%/}"
    sparkrun registry list 2>/dev/null \
        | awk 'NR>2 {print $2}' \
        | while read -r url; do
            url="${url%.git}"
            url="${url%/}"
            [ "$url" = "$norm_want" ] && { echo hit; break; }
        done | grep -q hit
}

cmd_add() {
    _require_sparkrun
    local added=0 skipped=0 failed=0
    for url in "${DEFAULT_REGISTRY_URLS[@]}"; do
        if _registry_known "$url"; then
            echo "  [skip] already registered: $url"
            skipped=$((skipped + 1))
            continue
        fi
        echo "  [add]  $url"
        if sparkrun registry add "$url" >/dev/null 2>&1; then
            added=$((added + 1))
        else
            # Retry without silencing so the user sees the actual error on
            # failure (auth issues, rate limits, unreachable host, etc.).
            echo "    retrying with output for diagnostics..."
            if sparkrun registry add "$url"; then
                added=$((added + 1))
            else
                echo "    !! failed to register $url — skipping." >&2
                failed=$((failed + 1))
            fi
        fi
    done
    echo ""
    echo "Recipe registries — added: $added, already present: $skipped, failed: $failed"
    if [ "$failed" -gt 0 ]; then
        echo "Note: transient failures (network, rate limit) are safe to retry — 'dgx-recipes add' is idempotent." >&2
    fi
}

cmd_list() {
    _require_sparkrun
    sparkrun registry list
}

cmd_update() {
    _require_sparkrun
    # `sparkrun registry update` (no name) refreshes every enabled registry
    # AND restores any missing default registries, so this doubles as a
    # "repair" command for users who accidentally removed one.
    sparkrun registry update
}

cmd_status() {
    echo "dgx-toolbox recipe registries"
    if ! command -v sparkrun >/dev/null 2>&1; then
        echo "  sparkrun: NOT INSTALLED (run setup/dgx-global-base-setup.sh)"
        return
    fi
    echo "  sparkrun: $(sparkrun --version 2>/dev/null || echo 'unknown')"
    echo ""
    echo "  Registered registries:"
    sparkrun registry list 2>/dev/null | sed 's/^/    /' || echo "    (none)"
    echo ""
    echo "  Default URLs this script installs:"
    for url in "${DEFAULT_REGISTRY_URLS[@]}"; do
        echo "    $url"
    done
}

main() {
    local cmd="${1:-add}"
    shift || true
    case "$cmd" in
        add)      cmd_add ;;
        list)     cmd_list ;;
        update)   cmd_update ;;
        status)   cmd_status ;;
        -h|--help|help)
            sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
            ;;
        *)
            echo "Unknown subcommand: $cmd" >&2
            echo "Try: dgx-recipes add | list | update | status" >&2
            exit 2
            ;;
    esac
}

main "$@"
