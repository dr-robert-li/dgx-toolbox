# Phase 4: CLI, Status, Revert, and Docs - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Unified CLI dispatcher with all subcommands, status dashboard, interrupt-safe revert, progress bars, headless compatibility, project root reorganization into subfolders, and full documentation updates (README, CHANGELOG, .gitignore, aliases). This is the final phase.

</domain>

<decisions>
## Implementation Decisions

### Status output format
- Columns per model: name, ecosystem (HF/Ollama), tier (HOT/COLD/BROKEN), size, last used, days until migration
- Sorted by size (largest first)
- Full dashboard summary after model table:
  - Drive totals: "Hot: 26GB/3.7TB used, Cold: 0B/938GB used"
  - Model counts: "8 models hot, 0 cold, 0 broken"
  - Watcher status: running/stopped + PID
  - Cron status: installed/not installed + next run time
  - Last migration: timestamp or "never"

### Revert safety flow
- Default: preview what will be moved back (models, sizes, total), then prompt "Proceed? [y/N]"
- `--force` flag skips confirmation (for scripts/NVIDIA Sync)
- Cleanup scope after revert:
  - Remove modelstore/ directory on cold drive
  - Uninstall modelstore crontab entries
  - Stop watcher daemon, remove pidfile
  - KEEP `~/.modelstore/config.json` (makes reinit easier)
- Interrupt safety: resume from `op_state.json` — tracks which models already reverted, picks up where it left off on re-run

### Documentation scope
- README: integrated "Model Store" section alongside existing sections (Inference, Data, Eval, etc.) with subcommands table + quick start
- Aliases: single `modelstore` alias only — subcommands handle the rest. Add to both `~/.bash_aliases` and `example.bash_aliases` with description comment.
- NVIDIA Sync: add a custom app entry that runs `modelstore status` and returns output (CLI tool, no port)
- CHANGELOG: add modelstore release entry
- .gitignore: exclude modelstore runtime artifacts (`~/.modelstore/` is outside repo, but any test fixtures or temp files inside repo should be ignored)

### Project root reorganization
- The dgx-toolbox root is cluttered with 20+ scripts. Reorganize into subfolders:
  - Keep in root: `README.md`, `CHANGELOG.md`, `.gitignore`, `example.bash_aliases`, `example.vllm-model`, `lib.sh`, `modelstore.sh`
  - Move launcher scripts to subdirectories by category (e.g., `inference/`, `data/`, `containers/`, `setup/`)
- Update ALL references: aliases in `~/.bash_aliases`, `example.bash_aliases`, README paths, NVIDIA Sync custom app commands, docker-compose files
- This is a breaking change for existing aliases — the alias update must be atomic with the file moves

### Claude's Discretion
- Exact subfolder names and file groupings for root reorganization
- Status table formatting (printf widths, column alignment)
- Progress bar implementation details (pv vs rsync --info=progress2 — both already used in Phase 3)
- Broken symlink detection method in status
- .gitignore entries for modelstore test artifacts

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase 3 code (source of truth for migrate/recall patterns)
- `modelstore/cmd/migrate.sh` — `op_state.json` interrupt-safe pattern, dry-run table format, flock
- `modelstore/cmd/recall.sh` — Synchronous recall with fuser guard, usage.json update
- `modelstore/cron/migrate_cron.sh` — Cron wrapper pattern
- `modelstore/cron/disk_check_cron.sh` — Disk check with notification

### Phase 1 code (CLI dispatcher)
- `modelstore.sh` — Existing thin router (case statement dispatching init). Needs status, migrate, recall, revert added.
- `modelstore/cmd/init.sh` — `install_cron` function references `cron/migrate_cron.sh` and `cron/disk_cron.sh`

### Project root files to reorganize
- All `start-*.sh`, `setup-*.sh`, `ngc-*.sh`, `unsloth-*.sh`, `triton-*.sh` scripts in root
- `docker-compose.*.yml` files
- `build-toolboxes.sh`, `status.sh`
- `eval-toolbox-build.sh`, `eval-toolbox.sh`, `eval-toolbox-jupyter.sh`
- `data-toolbox-build.sh`, `data-toolbox.sh`, `data-toolbox-jupyter.sh`
- `dgx-global-base-setup.sh`

### Documentation files
- `README.md` — Full project README, needs modelstore section + updated paths after reorg
- `CHANGELOG.md` — Needs modelstore entry
- `.gitignore` — Needs modelstore runtime artifact exclusions
- `example.bash_aliases` — Needs modelstore alias + updated paths after reorg
- `~/.bash_aliases` — Live aliases, must match example after reorg

### Conventions
- `.planning/codebase/CONVENTIONS.md` — Naming, code style

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `modelstore.sh` — CLI router already dispatches `init`. Add `status|migrate|recall|revert` cases.
- `cmd/migrate.sh` — `op_state.json` pattern for interrupt-safe revert
- `lib/audit.sh` — `audit_log()` for logging revert events
- `lib/notify.sh` — `notify_user()` for revert completion notification
- `hooks/watcher.sh` — pidfile at `$HOME/.modelstore/watcher.pid` for status display
- `status.sh` (root) — Existing DGX status script pattern for formatting reference
- `lib.sh` (root) — Shared functions, sourced by all launcher scripts via relative path

### Established Patterns
- Case statement routing in `modelstore.sh`
- `load_config` at entry of every cmd/ script
- `op_state.json` for interrupt-safe multi-step operations
- `flock` for concurrency
- printf tables with fixed-width columns (used in init model scan)
- `#!/usr/bin/env bash` + `set -euo pipefail` in executables

### Integration Points
- `modelstore.sh` case statement — add `status`, `migrate`, `recall`, `revert`
- `example.bash_aliases` — add `modelstore` alias, update all paths after reorg
- `~/.bash_aliases` — update all paths after reorg
- README — add Model Store section, update all script paths
- NVIDIA Sync custom app table in README — update commands after reorg, add modelstore status entry
- `docker-compose.*.yml` — may reference scripts by path (check)

</code_context>

<specifics>
## Specific Ideas

- The root reorganization should be done FIRST (before docs update) so all documentation reflects the final paths
- Suggested folder structure: `inference/` (vllm, litellm, ollama, open-webui), `data/` (data-toolbox, label-studio, argilla), `eval/` (eval-toolbox, triton), `containers/` (ngc-pytorch, ngc-jupyter, unsloth), `setup/` (dgx-global-base-setup), keeping `modelstore/`, `lib.sh`, `modelstore.sh`, compose files, and docs in root

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 04-cli-status-revert-and-docs*
*Context gathered: 2026-03-22*
