# Requirements: Model Store — Tiered Storage for DGX Spark

**Defined:** 2026-03-21
**Core Value:** Models are always accessible regardless of which tier they're on while the hot drive never fills up with stale models.

## v1 Requirements

Requirements for initial release. Each maps to roadmap phases.

### Initialization

- [x] **INIT-01**: User can run interactive init wizard that shows filesystem tree and selects hot/cold drives and paths
- [x] **INIT-02**: Init creates directory structure on both drives with user confirmation
- [x] **INIT-03**: User can configure retention period (default 14 days) during init
- [x] **INIT-04**: User can configure cron schedule (default 2 AM) during init
- [x] **INIT-05**: Init persists all settings to a config file on disk
- [x] **INIT-06**: Init validates cold drive filesystem (rejects exFAT, requires ext4/xfs)
- [x] **INIT-07**: Init scans existing models and shows what's where with sizes
- [x] **INIT-08**: User can reinitialize to different drives with progress bars for migration and garbage collection on old paths

### Migration

- [x] **MIGR-01**: Daily cron job migrates models unused beyond retention period from hot to cold store using rsync
- [x] **MIGR-02**: Migrated models are replaced with symlinks so all paths remain valid
- [x] **MIGR-03**: Symlink replacement is atomic (ln + mv -T pattern, no broken window)
- [x] **MIGR-04**: HuggingFace models are migrated as whole `models--*/` directories to preserve internal relative symlinks
- [x] **MIGR-05**: Ollama models are migrated with manifest-aware blob reference counting (shared blobs not moved if still referenced)
- [x] **MIGR-06**: Concurrent migrations are prevented via flock
- [x] **MIGR-07**: User can run dry-run mode to see what would migrate without moving data
- [x] **MIGR-08**: All migration and recall operations are logged to an audit file

### Recall

- [x] **RECL-01**: When a model is actively needed, it is moved back from cold to hot store automatically
- [x] **RECL-02**: Recall replaces the symlink with real files and resets the retention timer
- [x] **RECL-03**: Launcher hooks in vLLM, eval-toolbox, data-toolbox, and Unsloth scripts trigger recall and update usage timestamps

### Usage Tracking

- [x] **TRCK-01**: Usage tracker maintains a timestamp manifest file per model, updated on every load
- [x] **TRCK-02**: Existing DGX Toolbox launcher scripts (vLLM, eval-toolbox, data-toolbox, Unsloth) are hooked to call the usage tracker

### Safety

- [x] **SAFE-01**: Migration refuses to create symlinks if cold drive is not mounted (verified via `mountpoint -q`)
- [x] **SAFE-02**: Migration checks available space on destination drive with 10% safety margin before moving
- [x] **SAFE-03**: Cron job sends desktop notification via `notify-send` if either drive exceeds 98% usage
- [x] **SAFE-04**: Notifications fall back to log file when desktop session is unavailable
- [x] **SAFE-05**: All multi-step operations use a state file for interrupt-safe, idempotent resumption
- [x] **SAFE-06**: Ollama server state is checked before migrating Ollama models (warn if running)

### CLI & Operations

- [ ] **CLI-01**: Single `modelstore` CLI entry point dispatches to subcommands: init, status, recall, revert, migrate
- [ ] **CLI-02**: Individual scripts exist for cron and NVIDIA Sync integration
- [ ] **CLI-03**: `modelstore status` shows what's on each tier with sizes, last-used timestamps, and space available
- [ ] **CLI-04**: `modelstore revert` moves all models back to internal, removes all symlinks, undoes all tiering
- [ ] **CLI-05**: Revert is interrupt-safe and idempotent (can be re-run if interrupted)
- [ ] **CLI-06**: Large migrations show progress bars (pv/rsync --info=progress2)
- [ ] **CLI-07**: Non-interactive commands work headless for NVIDIA Sync (no TTY required)

### Documentation

- [ ] **DOCS-01**: README updated with modelstore section, aliases, and NVIDIA Sync instructions
- [ ] **DOCS-02**: CHANGELOG updated with modelstore release entry
- [ ] **DOCS-03**: .gitignore updated for modelstore runtime artifacts
- [ ] **DOCS-04**: example.bash_aliases updated with modelstore aliases

## v2 Requirements

### Advanced Features

- **ADV-01**: Per-model pinning (always keep specific models on hot store)
- **ADV-02**: Scheduled recall (pre-warm models before known usage windows)
- **ADV-03**: Multiple cold tiers (USB drive, NAS mount, etc.)

## Out of Scope

| Feature | Reason |
|---------|--------|
| Cloud storage tiering (S3, GCS) | Local drives only — cloud adds latency and complexity |
| Automatic model downloading | Only manages storage of already-downloaded models |
| RAID or multi-drive pooling | Two-tier only (hot + cold), not a storage pool |
| Python runtime dependency | Core scripts must be bash-only for host execution |
| FUSE filesystem | Over-engineered for the use case; symlinks are simpler and proven |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| INIT-01 | Phase 1 | Complete |
| INIT-02 | Phase 1 | Complete |
| INIT-03 | Phase 1 | Complete |
| INIT-04 | Phase 1 | Complete |
| INIT-05 | Phase 1 | Complete |
| INIT-06 | Phase 1 | Complete |
| INIT-07 | Phase 1 | Complete |
| INIT-08 | Phase 1 | Complete |
| TRCK-01 | Phase 2 | Complete |
| TRCK-02 | Phase 2 | Complete |
| SAFE-01 | Phase 2 | Complete |
| SAFE-02 | Phase 2 | Complete |
| SAFE-06 | Phase 2 | Complete |
| MIGR-01 | Phase 3 | Complete |
| MIGR-02 | Phase 3 | Complete |
| MIGR-03 | Phase 3 | Complete |
| MIGR-04 | Phase 3 | Complete |
| MIGR-05 | Phase 3 | Complete |
| MIGR-06 | Phase 3 | Complete |
| MIGR-07 | Phase 3 | Complete |
| MIGR-08 | Phase 3 | Complete |
| RECL-01 | Phase 3 | Complete |
| RECL-02 | Phase 3 | Complete |
| RECL-03 | Phase 3 | Complete |
| SAFE-03 | Phase 3 | Complete |
| SAFE-04 | Phase 3 | Complete |
| SAFE-05 | Phase 3 | Complete |
| CLI-01 | Phase 4 | Pending |
| CLI-02 | Phase 4 | Pending |
| CLI-03 | Phase 4 | Pending |
| CLI-04 | Phase 4 | Pending |
| CLI-05 | Phase 4 | Pending |
| CLI-06 | Phase 4 | Pending |
| CLI-07 | Phase 4 | Pending |
| DOCS-01 | Phase 4 | Pending |
| DOCS-02 | Phase 4 | Pending |
| DOCS-03 | Phase 4 | Pending |
| DOCS-04 | Phase 4 | Pending |

**Coverage:**
- v1 requirements: 38 total
- Mapped to phases: 38
- Unmapped: 0

---
*Requirements defined: 2026-03-21*
*Last updated: 2026-03-21 after roadmap creation*
