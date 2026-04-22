#!/usr/bin/env bash
# dgx-discover — list and search every recipe you can actually run on this box.
#
# Thin convenience wrapper around sparkrun's built-in `recipe list` / `recipe
# search` commands plus this repo's local recipes/ directory. Answers the
# question "what models can I pull/serve right now?" without needing to
# memorise the underlying sparkrun flags.
#
# Usage:
#   dgx-discover                           # everything: local recipes + all registries (visible)
#   dgx-discover list                      # same as above
#   dgx-discover list --all                # include hidden-by-default registries
#   dgx-discover list --runtime vllm       # filter by runtime (vllm|sglang|llama-cpp)
#   dgx-discover list --registry <name>    # filter to a specific registry
#   dgx-discover local                     # only recipes from ~/dgx-toolbox/recipes/
#   dgx-discover registries                # list registered recipe registries
#   dgx-discover search <query>            # search by name / model / description
#   dgx-discover show <recipe>             # show resolved recipe details (incl. VRAM estimate)
#   dgx-discover update                    # refresh registries (git pull upstream)
#
# All subcommands accept extra flags that are passed through to sparkrun, so
# e.g. `dgx-discover list --json` works.
#
# Precedence: sparkrun's own registry state is the source of truth. This
# script just stitches the common calls together with DGX-Spark-friendly
# defaults and clear section headers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_RECIPES_DIR="${DGX_RECIPES_DIR:-${REPO_DIR}/recipes}"

_require_sparkrun() {
    if ! command -v sparkrun >/dev/null 2>&1; then
        echo "ERROR: sparkrun not on PATH. Run setup/dgx-global-base-setup.sh first." >&2
        exit 1
    fi
}

_print_section() {
    echo ""
    echo "=============================================================="
    echo "  $1"
    echo "=============================================================="
}

_list_local_recipes() {
    # Emit a compact table of YAML recipes found in the local recipes/ dir.
    # Columns: name | model | runtime (best-effort; parses YAML with grep/awk
    # to avoid a Python dependency for this simple listing).
    if [ ! -d "$LOCAL_RECIPES_DIR" ]; then
        echo "  (no local recipes directory at ${LOCAL_RECIPES_DIR})"
        return
    fi
    local found=0
    printf "  %-40s  %-50s  %s\n" "RECIPE" "MODEL" "RUNTIME"
    printf "  %-40s  %-50s  %s\n" "----------------------------------------" "--------------------------------------------------" "-------"
    # shellcheck disable=SC2044
    for f in "$LOCAL_RECIPES_DIR"/*.yaml "$LOCAL_RECIPES_DIR"/*.yml; do
        [ -e "$f" ] || continue
        found=1
        local name model runtime
        name="$(basename "$f")"
        name="${name%.yaml}"
        name="${name%.yml}"
        # Grab the first line matching model: / runtime: at col 0 or nested once.
        # Capture everything after the colon so values with $VARS or spaces
        # are preserved, then trim leading whitespace and surrounding quotes.
        model="$(awk 'match($0, /^[[:space:]]*model:[[:space:]]*/) {print substr($0, RSTART + RLENGTH); exit}' "$f" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
        runtime="$(awk 'match($0, /^[[:space:]]*runtime:[[:space:]]*/) {print substr($0, RSTART + RLENGTH); exit}' "$f" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
        [ -z "$runtime" ] && runtime="(inferred)"
        [ -z "$model" ] && model="(templated)"
        # Flag templated models ($VAR / ${VAR}) for clarity.
        case "$model" in
            *\$*) model="$model (templated)" ;;
        esac
        printf "  %-40s  %-50s  %s\n" "$name" "$model" "$runtime"
    done
    if [ "$found" -eq 0 ]; then
        echo "  (no *.yaml recipes found in ${LOCAL_RECIPES_DIR})"
    fi
    echo ""
    echo "  Run any of the above with:  vllm <recipe-name>"
}

cmd_registries() {
    _require_sparkrun
    _print_section "Registered sparkrun recipe registries"
    sparkrun registry list "$@"
    echo ""
    echo "  Tip: 'dgx-recipes add' to restore the default upstream registries,"
    echo "       'dgx-recipes update' to git-pull refresh them."
}

cmd_local() {
    _print_section "Local recipes in ${LOCAL_RECIPES_DIR}"
    _list_local_recipes
}

cmd_list() {
    _require_sparkrun
    # Show local recipes first (most likely what users want on this box),
    # then upstream registry recipes. Both sections so users don't miss
    # either source.
    _print_section "Local recipes in ${LOCAL_RECIPES_DIR}"
    _list_local_recipes

    _print_section "Recipes from registered sparkrun registries"
    # Forward flags (--runtime, --registry, --all, --json, a query arg) to
    # sparkrun's own list command — which already handles formatting,
    # filters, and JSON output. `sparkrun list` is the top-level alias for
    # `sparkrun recipe list`.
    sparkrun list "$@"

    echo ""
    echo "  Run a recipe:  vllm <recipe-name>      (local-first, then registries)"
    echo "  Inspect:       dgx-discover show <recipe-name>"
    echo "  Filter:        dgx-discover list --runtime vllm"
}

cmd_search() {
    _require_sparkrun
    if [ "$#" -lt 1 ]; then
        echo "Usage: dgx-discover search <query> [sparkrun search options...]" >&2
        exit 2
    fi
    _print_section "Searching registered registries for: $*"
    sparkrun search "$@"
}

cmd_show() {
    _require_sparkrun
    if [ "$#" -lt 1 ]; then
        echo "Usage: dgx-discover show <recipe-name> [sparkrun show options...]" >&2
        exit 2
    fi
    local recipe="$1"; shift
    # Prefer a local path match so sparkrun show picks up unreleased edits
    # from this repo's recipes/ dir without needing a registry sync.
    local local_path="${LOCAL_RECIPES_DIR}/${recipe}.yaml"
    if [ -f "$recipe" ]; then
        sparkrun show "$recipe" "$@"
    elif [ -f "$local_path" ]; then
        sparkrun show "$local_path" "$@"
    else
        sparkrun show "$recipe" "$@"
    fi
}

cmd_update() {
    _require_sparkrun
    _print_section "Refreshing recipe registries (git pull upstream)"
    sparkrun registry update "$@"
}

cmd_help() {
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
    # If the first token starts with `-` (e.g. `--runtime vllm`), treat the
    # whole argv as flags to the default `list` subcommand so
    # `dgx-discover --runtime vllm` works without a leading subcommand word.
    if [ "$#" -gt 0 ]; then
        case "$1" in
            -h|--help) cmd_help; return ;;
            -*)        cmd_list "$@"; return ;;
        esac
    fi
    local cmd="${1:-list}"
    if [ "$#" -gt 0 ]; then
        shift
    fi
    case "$cmd" in
        list|ls)              cmd_list "$@" ;;
        local)                cmd_local "$@" ;;
        registries|registry)  cmd_registries "$@" ;;
        search)               cmd_search "$@" ;;
        show|inspect)         cmd_show "$@" ;;
        update|refresh)       cmd_update "$@" ;;
        help)                 cmd_help ;;
        *)
            # If the first token doesn't match a subcommand, treat it as a
            # search query — lets `dgx-discover qwen` just work.
            cmd_search "$cmd" "$@"
            ;;
    esac
}

main "$@"
