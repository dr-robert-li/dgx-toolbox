# Phase 3: Migration, Recall, and Safety - Context

**Gathered:** 2026-03-21
**Status:** Ready for planning

<domain>
## Phase Boundary

Automated cron-based migration of stale models to cold storage, transparent recall (auto + manual), concurrency guards via flock, disk usage warnings with desktop notification and log fallback, dry-run mode, and audit logging. Does NOT include CLI dispatcher, status command, revert, or documentation updates — those are Phase 4.

</domain>

<decisions>
## Implementation Decisions

### Recall trigger behavior
- Both automatic and manual recall: watcher daemon auto-recalls on cold symlink access + `modelstore recall <model>` for explicit control
- Models on cold storage remain loadable via symlink (slower but functional) — recall moves them back to hot for speed
- Recall is synchronous (block and wait) — the model consumer waits until recall completes, then loads normally. No background recall.
- This means a 24GB model recall may take minutes — acceptable tradeoff vs failing or loading slowly from cold

### Dry-run output format
- `modelstore migrate --dry-run` shows a full table: model name, size, last used, days since use, source→destination
- Also shows total size to be moved and available space on cold drive
- Additionally shows models that WON'T be migrated and why ("used within 14 days", "already on cold", etc.)
- Two sections: "Would migrate" and "Keeping hot"

### Disk warning notifications
- Frequency: fire once when 98% threshold crossed, suppress until usage drops below 98% (no daily nagging)
- Track suppression state in `~/.modelstore/disk_alert_sent_<drive_hash>` marker files
- Content: specific and actionable — "Hot storage at 98.5% (3.64TB/3.7TB). Run: modelstore migrate"
- Desktop: `notify-send` with `DBUS_SESSION_BUS_ADDRESS` injection from cron
- Fallback log: `~/.modelstore/alerts.log` when no desktop session available

### Audit log format
- Log ALL events: migrations, recalls, failures, disk warnings
- Format: JSON lines (one JSON object per line) — machine-parseable, easy to grep/jq
- Location: `~/.modelstore/audit.log`
- Fields per entry: `{"timestamp": "ISO-8601", "event": "migrate|recall|fail|disk_warning", "model": "path", "size_bytes": N, "source": "path", "dest": "path", "duration_sec": N, "trigger": "cron|manual|auto", "error": "msg or null"}`
- Rotation: annual — rotate at year boundary, keep all old files forever (e.g., `audit.2026.log`, `audit.2027.log`)

### Claude's Discretion
- flock file path and locking strategy for concurrent migration prevention
- State file format for interrupt-safe recall operations (SAFE-05)
- Cron script error handling and exit codes
- DBUS_SESSION_BUS_ADDRESS detection method from cron context
- Exact rsync flags for migration (beyond `--info=progress2` already decided)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase 2 code (adapters + watcher — source of truth)
- `modelstore/lib/hf_adapter.sh` — `hf_migrate_model`, `hf_recall_model` with rsync + atomic symlink swap pattern
- `modelstore/lib/ollama_adapter.sh` — `ollama_migrate_model`, `ollama_recall_model` stubs, `ollama_check_server` guard
- `modelstore/hooks/watcher.sh` — `ms_track_usage` with flock+jq, daemon lifecycle, pidfile pattern

### Phase 1 code (config + safety)
- `modelstore/lib/common.sh` — `check_cold_mounted`, `check_space`, `ms_log`, `ms_die`
- `modelstore/lib/config.sh` — `load_config`, `config_read` — provides `COLD_PATH`, `RETENTION_DAYS`, `CRON_HOUR`
- `modelstore/cmd/init.sh` — `install_cron` function (cron installation pattern, currently skips if cron/ dir missing)

### Research
- `.planning/research/ARCHITECTURE.md` — Atomic symlink swap (`ln -s` + `mv -T`), atime unreliability, Ollama server state checks
- `.planning/research/PITFALLS.md` — `mountpoint -q` vs `test -d`, race conditions during migration, `notify-send` DBUS issue from cron, interrupt-safe state files

### Conventions
- `.planning/codebase/CONVENTIONS.md` — Naming, code style, variable conventions

No external specs — requirements fully captured in decisions above.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `hf_adapter.sh:hf_migrate_model()` — Already has rsync + symlink + mount/space guards. Phase 3 `cmd/migrate.sh` calls this.
- `ollama_adapter.sh:ollama_migrate_model()` — Stub with server block + mount/space guards. Phase 3 fills the body.
- `watcher.sh:ms_track_usage()` — flock+jq atomic JSON write pattern. Reuse for audit log writes.
- `common.sh:check_cold_mounted()` / `check_space()` — Already battle-tested in adapters.
- `init.sh:install_cron()` — Cron installation pattern. Phase 3 creates the actual cron scripts it references.

### Established Patterns
- flock for concurrency: `watcher.sh` uses `flock -n` on pidfile, `flock -x` on usage.json
- JSON via jq: all config and usage data is JSON, read/written via jq
- `set -euo pipefail` in executables
- BASH_SOURCE for self-relative paths in sourced libs
- Adapters source common.sh + config.sh, call `load_config` on entry

### Integration Points
- `modelstore.sh` case statement needs: `migrate`, `recall` subcommands
- `cron/migrate_cron.sh` — called by crontab entry (installed by `init.sh:install_cron`)
- `cron/disk_check_cron.sh` — called by crontab entry
- `~/.modelstore/audit.log` — new file, written by migrate/recall/cron scripts
- `~/.modelstore/alerts.log` — new file, written by disk_check_cron
- `~/.modelstore/disk_alert_sent_*` — marker files for notification suppression

</code_context>

<specifics>
## Specific Ideas

- The watcher daemon should trigger recall by calling `cmd/recall.sh` directly when it detects cold symlink access — same code path as manual recall
- Audit log entries should include a `trigger` field distinguishing `cron`, `manual`, and `auto` (watcher-triggered) recalls

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 03-migration-recall-and-safety*
*Context gathered: 2026-03-21*
