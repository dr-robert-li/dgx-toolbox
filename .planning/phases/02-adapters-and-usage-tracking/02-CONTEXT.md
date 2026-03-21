# Phase 2: Adapters and Usage Tracking - Context

**Gathered:** 2026-03-21
**Status:** Ready for planning

<domain>
## Phase Boundary

HF and Ollama storage adapters with full operation set (enumerate, size, migrate, recall, symlink), a background usage tracker daemon (docker events + inotifywait), and safety functions (mount check, space check, Ollama server state). Does NOT include the migration cron, recall triggers from launchers, or disk warning notifications — those are Phase 3.

</domain>

<decisions>
## Implementation Decisions

### Usage timestamp format
- Single JSON manifest at `~/.modelstore/usage.json`
- Model IDs are path-based (the actual directory/blob path as ID — most precise)
- Timestamps updated on both launcher start (container/process launch) AND specific model load when parseable from args/config
- Format: `{"<path>": "<ISO-8601 timestamp>"}`

### Launcher hook integration — Background daemon
- NO modifications to existing launcher scripts — zero-touch approach
- Background watcher daemon monitors both Docker events (for containerized tools) and filesystem access via `inotifywait` (for direct access like `ollama run`)
- Docker events: watch `docker events --filter event=start`, parse image/args to identify which model
- Filesystem: `inotifywait -m -e access` on HF cache and Ollama models dirs
- Daemon lifecycle: cron ensures it's running (pidfile check). Not a systemd service.
- Must be agnostic — works for any script that touches model files, not just the four named launchers
- Failure mode: warn to stderr and continue — tracker failure never blocks model access

### Ollama server interaction
- Detection: `systemctl is-active ollama` first, then `/api/tags` for loaded models
- Warning level: BLOCK — refuse to operate on Ollama models while server is active. User must stop Ollama first.
- Permissions: API-only for all operations — NO sudo, NO direct file access
  - Enumeration: `/api/tags` for model list with sizes
  - Migration (Phase 3): `ollama cp` to copy model to cold-mounted path, `ollama rm` to remove from hot
  - This avoids all permission issues with the system `ollama` user's files

### HF vs Ollama adapter scope — Full adapters
- Both adapters expose full operation set in Phase 2 (not just enumerate):
  - `list_models()` — enumerate all models with sizes
  - `get_model_size(model_id)` — size of a single model
  - `get_model_path(model_id)` — full path to model
  - `migrate_model(model_id, cold_path)` — move to cold + create symlink
  - `recall_model(model_id, hot_path)` — move back from cold, replace symlink
- HF migration unit: whole `models--org--name/` directory (preserves internal relative symlinks — confirmed by research)
- Ollama migration: API-driven (`ollama cp` to cold path, `ollama rm` from hot). No filesystem operations.

### Claude's Discretion
- inotifywait event mask (which events beyond `access` to watch)
- Docker event parsing logic (how to extract model name from container args)
- JSON manifest locking strategy (flock on usage.json)
- Adapter function signatures and error handling patterns

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase 1 code (source of truth for patterns)
- `modelstore/lib/common.sh` — `check_cold_mounted`, `check_space`, `validate_cold_fs`, `ms_log`, `ms_die` — all safety functions already implemented
- `modelstore/lib/config.sh` — `config_read`, `load_config`, `write_config` — JSON config via jq
- `modelstore/cmd/init.sh` — `scan_hf_models`, `scan_ollama_models` — model enumeration patterns already implemented (Python API for HF, HTTP API for Ollama)

### Research
- `.planning/research/ARCHITECTURE.md` — Component boundaries, HF cache internals (blobs/snapshots/refs), Ollama blob/manifest structure, atomic symlink swap pattern
- `.planning/research/PITFALLS.md` — atime unreliability (why explicit manifest), Ollama shared blobs across models, race conditions during migration
- `.planning/research/STACK.md` — inotify-tools, flock, rsync recommendations

### Conventions
- `.planning/codebase/CONVENTIONS.md` — Naming patterns, code style, variable conventions

No external specs — requirements fully captured in decisions above.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `init.sh:scan_hf_models()` — Already scans HF via Python `scan_cache_dir()` API with fallback to directory walk. Adapter can reuse this pattern.
- `init.sh:scan_ollama_models()` — Already scans Ollama via `/api/tags` HTTP endpoint. Adapter reuses this.
- `common.sh:check_cold_mounted()` — Ready to use in adapters before any cold-path operation
- `common.sh:check_space()` — Ready to use before migration operations
- `config.sh:load_config()` — Sets `HOT_HF_PATH`, `HOT_OLLAMA_PATH`, `COLD_PATH` environment variables

### Established Patterns
- Functions prefixed with `ms_` for modelstore namespace
- JSON config via jq — adapters should use same pattern for usage.json
- `set -euo pipefail` in executables, no `set -e` in sourced libs
- BASH_SOURCE for self-relative paths in sourced files

### Integration Points
- `modelstore.sh` case statement needs new subcommands: `track`, `list-models` (or these are internal-only)
- `~/.modelstore/usage.json` — new file, read by migration cron (Phase 3)
- `hooks/` directory exists with `.gitkeep` — daemon script goes here
- Adapters go in `lib/hf_adapter.sh` and `lib/ollama_adapter.sh`

</code_context>

<specifics>
## Specific Ideas

- The background daemon should be a single script (`hooks/watcher.sh`) that combines docker event monitoring and inotifywait in parallel (two background processes within one script, managed by the same pidfile)
- The user explicitly wants API-only Ollama operations to avoid permission complexity — design the Ollama adapter so it NEVER calls `sudo` or accesses `/usr/share/ollama` directly

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 02-adapters-and-usage-tracking*
*Context gathered: 2026-03-21*
