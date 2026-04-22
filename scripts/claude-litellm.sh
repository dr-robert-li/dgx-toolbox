#!/usr/bin/env bash
# claude-litellm.sh — Thin wrapper that sources the sparkrun-claude package.
#
# The real logic lives in scripts/sparkrun-claude/ (portable, self-locating).
# This file exists for backward compatibility with the existing alias in
# example.bash_aliases:
#
#     alias claude-litellm='source ~/dgx-toolbox/scripts/claude-litellm.sh'
#
# Any arguments are forwarded to the underlying script.

_claude_litellm_wrapper_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=./sparkrun-claude/sparkrun-claude
. "${_claude_litellm_wrapper_dir}/sparkrun-claude/sparkrun-claude" "$@"
unset _claude_litellm_wrapper_dir
