# Phase 1: Foundation and Init - Context

**Gathered:** 2026-03-21
**Status:** Ready for planning

<domain>
## Phase Boundary

Config infrastructure, shared library functions, and an interactive init wizard that produces a validated config file all other scripts depend on. Includes reinit for drive reconfiguration. Does NOT include migration logic, recall, or usage tracking — those are Phase 2+.

</domain>

<decisions>
## Implementation Decisions

### Script structure
- Scripts live in `~/dgx-toolbox/modelstore/` subdirectory with `lib/`, `cmd/`, `hooks/` inside
- CLI entry point at `~/dgx-toolbox/modelstore.sh` — thin router that sources libs, then `exec`'s `cmd/init.sh`, `cmd/status.sh`, etc.
- Separate modelstore libs (`modelstore/lib/common.sh`, `modelstore/lib/config.sh`) — source the existing `lib.sh` plus own libs
- Do NOT extend the existing `lib.sh` directly — modelstore has its own lib namespace

### Init wizard UX
- Check for `gum` (Charm) at startup; if missing, offer to install from Charm apt repo; fall back to `read -p` if user declines
- Filesystem tree preview: show `lsblk` overview first (block devices, sizes, filesystems, mount points), then `ls -la` of top-level mount for the selected drive for confirmation
- Model scan output: formatted table with per-model name + size + last access time, subtotals per ecosystem (HF total, Ollama total), and grand total
- Init validates cold drive filesystem — reject exFAT, require ext4/xfs with clear explanation

### Reinit behavior
- When reinitializing to different drives, prompt user per reinit: "Migrate existing cold models to new cold drive, or recall everything to hot first?"
- After reinit migration complete, auto-cleanup old modelstore directories on old cold drive (after confirming migration success)
- Auto-backup old config as `config.json.bak.<timestamp>` before overwriting
- Config backup retention: 30 days by default (configurable), old backups cleaned up on reinit

### Claude's Discretion
- Config file format (JSON vs key=value) — choose what's easiest to parse in bash
- Exact gum component choices (gum choose, gum input, gum confirm, etc.)
- Table formatting implementation (printf, column, or gum table)
- Error message wording and exit codes

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Existing codebase
- `lib.sh` — Shared function library; modelstore libs source this for `get_ip`, `ensure_dirs`, etc.
- `example.bash_aliases` — Template for user aliases; modelstore aliases go here
- `.planning/research/STACK.md` — Stack recommendations: rsync, flock, gum, `mountpoint -q`
- `.planning/research/ARCHITECTURE.md` — Component boundaries, config file as backbone dependency
- `.planning/research/PITFALLS.md` — `mountpoint -q` vs `test -d`, filesystem rejection, state file design

### Conventions
- `.planning/codebase/CONVENTIONS.md` — Naming patterns (kebab-case files, UPPERCASE vars, `set -e`)
- `.planning/codebase/STRUCTURE.md` — Directory layout and file organization patterns

No external specs — requirements fully captured in decisions above.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `lib.sh`: `get_ip()`, `ensure_dirs()`, `print_banner()` — source for common operations
- `setup-litellm-config.sh`: Pattern for interactive config generation with service detection + prompts
- `status.sh`: Pattern for formatted system status output with `printf` tables

### Established Patterns
- Shebang: `#!/usr/bin/env bash` + `set -e`
- Variables: UPPERCASE at script top
- File naming: kebab-case, `start-` prefix for services, `-sync` suffix for Sync variants
- Docker scripts source `lib.sh` via `source "$(dirname "$0")/lib.sh"`

### Integration Points
- `modelstore.sh` CLI entry point will be aliased in `~/.bash_aliases` and `example.bash_aliases`
- Launcher hooks (Phase 2) will add lines to existing `start-vllm.sh`, `eval-toolbox.sh`, `data-toolbox.sh`, `unsloth-studio.sh`
- Config file at `~/.modelstore/config.json` will be read by all subsequent phases

</code_context>

<specifics>
## Specific Ideas

No specific requirements — open to standard approaches.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 01-foundation-and-init*
*Context gathered: 2026-03-21*
