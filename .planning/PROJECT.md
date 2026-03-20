# Model Store — Tiered Storage for DGX Spark

## What This Is

A tiered model storage system for NVIDIA DGX Spark that automatically manages ML model lifecycle between a fast internal NVMe ("hot" store) and an external drive ("cold" store). Models land on the hot store when downloaded, get migrated to cold storage after a configurable retention period (default 14 days of inactivity), and are recalled transparently when needed. Provides a single CLI (`modelstore`) plus individual scripts for cron and launcher integration.

## Core Value

Models are always accessible regardless of which tier they're on — symlinks ensure transparent access — while the hot drive never fills up with stale models.

## Requirements

### Validated

- ✓ External drive formatted and mounted (`/media/robert_li/modelstore-1tb`, ext4, `nofail` fstab) — existing
- ✓ HuggingFace cache at `~/.cache/huggingface/hub/` — existing
- ✓ Ollama models at `~/.ollama/models/` — existing
- ✓ Launcher scripts for vLLM, eval-toolbox, data-toolbox, Unsloth, Ollama — existing
- ✓ Cron available on host — existing
- ✓ GNOME desktop environment for `notify-send` — existing

### Active

- [ ] Interactive init: select hot/cold drives and paths with filesystem tree preview, confirm folder creation
- [ ] Usage tracker: touch timestamp per model on every load via launcher hooks
- [ ] Migration cron: daily at configurable time (default 2 AM), move stale models to cold store with symlinks
- [ ] Recall script: move model back from cold to hot on active use, replace symlink, reset timer
- [ ] Configurable retention period (default 14 days)
- [ ] Space checks: prevent migration if destination drive lacks space
- [ ] Disk usage monitoring: cron warns via `notify-send` if either drive exceeds 98% usage
- [ ] Drive mount check: migration refuses to create symlinks if cold drive is unmounted
- [ ] Reinitialize: reconfigure hot/cold drives with progress bars for migration and garbage collection
- [ ] Full revert: undo all tiering, move everything back to internal, remove all symlinks
- [ ] Status command: show what's on each tier, sizes, last-used timestamps, space available
- [ ] Single CLI entry point (`modelstore`) dispatching to subcommands: `init`, `status`, `recall`, `revert`, `migrate`
- [ ] Individual scripts for cron and Sync integration
- [ ] Hook existing DGX Toolbox launchers (vLLM, eval-toolbox, data-toolbox, Unsloth) to call usage tracker
- [ ] Update README, CHANGELOG, .gitignore for modelstore functionality

### Out of Scope

- RAID or multi-drive pooling — this is two-tier only (hot + cold)
- Automatic model downloading/pulling — only manages storage of already-downloaded models
- Cloud storage tiering (S3, GCS) — local drives only
- Per-model pinning (always keep on hot) — all models follow the same retention policy

## Context

- DGX Spark has a 3.7TB internal NVMe (system drive) and a 953.9GB external NVMe mounted at `/media/robert_li/modelstore-1tb`
- The 238.5GB external drive at `/media/robert_li/backup-256g` (exFAT) is a backup drive, not part of tiering
- Two model ecosystems: HuggingFace cache (file-based, symlink-friendly) and Ollama (blob-based, also symlink-friendly)
- All model consumers (vLLM, transformers, Ollama) resolve through symlinks transparently
- Existing `lib.sh` provides shared functions for DGX Toolbox scripts
- Desktop notifications via `notify-send` work on the GNOME session

## Constraints

- **Architecture**: aarch64 (ARM64) — all tools must be compatible
- **Symlink safety**: Must verify cold drive is mounted before creating symlinks; broken symlinks = model load failures
- **Non-destructive**: Init and revert must never delete model data — only move it
- **Bash only**: No Python dependencies for the core modelstore scripts (they run outside containers)
- **NVIDIA Sync compatible**: Scripts must work when invoked remotely via Sync (no TTY required for cron/migration)

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Symlinks over hard links | Symlinks work across filesystems (internal NVMe ↔ external NVMe) | — Pending |
| Configurable hot/cold at init | User may swap drives or add new ones later; reinit with migration handles this | — Pending |
| `notify-send` for disk warnings | DGX Spark runs GNOME; desktop notifications are the most visible alert | — Pending |
| Single `modelstore` CLI + individual scripts | CLI for interactive use, individual scripts for cron/hooks/Sync | — Pending |
| Bash only (no Python) | Core scripts run on host, not in containers; minimize dependencies | — Pending |

---
*Last updated: 2026-03-21 after initialization*
