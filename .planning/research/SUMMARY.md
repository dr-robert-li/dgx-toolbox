# Project Research Summary

**Project:** modelstore — Tiered ML Model Storage for DGX Spark
**Domain:** Symlink-based two-tier local storage management for ML model caches (HuggingFace + Ollama)
**Researched:** 2026-03-21
**Confidence:** HIGH

## Executive Summary

`modelstore` is a pure-bash CLI tool that implements LRU-based hot/cold tiering for ML model caches on a DGX Spark workstation. The hot tier is internal NVMe (`~/.cache/huggingface/hub/`, `~/.ollama/models/`); the cold tier is an external NVMe drive. Migration is fully automated via cron, transparent to all model consumers via symlinks, and requires no Python or network access — it manipulates the filesystem directly using `rsync`, `ln`, `flock`, and `coreutils`. The key design insight from research is that each cache ecosystem (HuggingFace, Ollama) requires its own adapter because their internal directory structures are fundamentally different: HF uses relative symlinks inside model directories (requiring whole-directory-as-unit migration), while Ollama uses a content-addressed blob store where blobs can be shared across models (requiring manifest-aware blob reference counting before any move).

The recommended architecture is a layered bash project: a thin CLI dispatcher routes to independent `cmd/` scripts that source shared `lib/` adapters. Cron invokes `cmd/` scripts directly — never the CLI dispatcher. This design means every script is independently testable and cron-safe without any TTY dependency. The config file produced by `init.sh` is the backbone dependency for every other component; without it, nothing else runs. Usage tracking must be done via explicit `touch` manifests in `~/.modelstore/usage/` rather than filesystem `atime`, because `relatime` mount options and symlink `atime` semantics make `atime` unreliable as a "model was loaded" signal.

The dominant risks are: (1) migrating while a model is open produces a ENOENT window between `mv` and `ln -s` — prevented by `lsof`/`fuser` checks and cron scheduling during off-hours; (2) cold drive unmount leaves dangling symlinks — prevented by `mountpoint -q` guard in every script that touches cold paths; (3) Ollama's manifest cache requires a server restart after any blob move — prevented by `systemctl is-active ollama` checks in the migration script. All three risks have deterministic prevention strategies documented in research.

## Key Findings

### Recommended Stack

The entire tool runs on system-installed utilities: bash 5.2.21, rsync 3.2.7, flock, coreutils (`stat`, `df`, `ln`, `touch`, `find`), and `notify-send` — all already present on the DGX Spark host. The only additions to install are `pv` and `inotify-tools` via `apt`. `gum` (Charm) is optional for the interactive init wizard and must degrade gracefully to `read -p` when absent or when running non-interactively.

**Core technologies:**
- **Bash 5.2**: Script runtime — on-host constraint, Bash 5.x provides associative arrays and `mapfile` needed for tracking logic
- **rsync `--remove-source-files`**: Cross-filesystem atomic migration — `mv` fails across filesystems; rsync deletes source only after successful transfer
- **flock**: Cron job serialization — file-descriptor locking auto-releases on crash, strictly safer than PID files
- **ln + mv -T (atomic swap)**: Symlink replacement — `mv -T` calls `rename(2)` which is atomic; there is no gap where the path is absent
- **mountpoint -q**: Cold drive guard — `test -d` passes even on unmounted mountpoints; only `mountpoint -q` correctly detects mount state
- **gum v0.17.0**: Interactive init UI (optional) — arm64 apt package available via Charm repo; must fall back to `read -p` when absent

### Expected Features

**Must have (table stakes — all P1):**
- Interactive init wizard — selects hot/cold paths, validates mounts, writes config, installs cron; everything else depends on the config it produces
- Symlink-based transparent access — model consumers (vLLM, transformers, Ollama) must see uninterrupted paths; symlinks must be atomic and whole-directory
- Drive mount validation (shared `lib/common.sh` function) — gates every migration, recall, and revert operation
- Usage timestamp tracking — explicit `touch ~/.modelstore/usage/{model-id}` from launcher hooks; `atime` is unreliable
- Launcher hook integration — one-liner `modelstore track <model>` added to vLLM, eval-toolbox, Unsloth, Ollama launchers
- Migration cron — daily, reads config, finds stale models, `rsync` to cold, creates atomic symlinks
- Recall script — inverse of migration; moves cold back to hot, replaces symlink with real directory
- Status command — unified table across HF + Ollama: tier, size, last-used, days until migration, drive totals
- Space-available check with 10% buffer (shared function)
- Disk usage warning cron — `notify-send` when either drive exceeds configurable threshold (default 98%)
- Full revert — idempotent; moves all cold models back to hot, removes symlinks; never deletes data

**Should have (P2 — add after core is validated):**
- Progress bars (`pv` / rsync `--info=progress2` fallback)
- Dry-run mode for migrate and revert
- Recall-on-access from launcher hooks (detects symlink to cold tier, recalls before exec)
- Per-model migration audit log
- NVIDIA Sync / headless compatibility hardening

**Defer (v2+):**
- Reinit/reconfigure with live migration (high complexity — diff between old and new config, partial-migration rollback)
- Interactive deletion TUI (like `huggingface-cli delete-cache`)
- Two-ecosystem blob-level deduplication analysis

### Architecture Approach

The system is organized into five layers: an entry layer (CLI dispatcher, cron wrappers, launcher hooks), a core logic layer (`config.sh`, `tracker.sh`, `migrate.sh`, `recall.sh`), a storage abstraction layer (per-ecosystem adapters: `hf_adapter.sh`, `ollama_adapter.sh`), a notification layer (`notify.sh` with DBus env injection for cron), and a physical storage layer (two NVMe drives). The adapters are the critical isolation boundary — all HF cache layout knowledge lives in `hf_adapter.sh`; all Ollama blob/manifest knowledge lives in `ollama_adapter.sh`. Neither migrate.sh nor recall.sh contains hardcoded paths or format knowledge.

**Major components:**
1. `lib/config.sh` — reads/writes `~/.modelstore/config`; sourced by every other script; defines all path and policy variables
2. `lib/common.sh` — mount check, space check, logging; shared by both adapters and all cmd/ scripts
3. `lib/hf_adapter.sh` — enumerates `models--*/` dirs, measures sizes, performs migrate/recall with whole-directory guarantee
4. `lib/ollama_adapter.sh` — parses manifests for blob digests, ref-counts blobs before migration, handles stop/restart of Ollama service
5. `cmd/migrate.sh` — core migration worker; calls adapters; checks Ollama server state; uses flock to prevent concurrent execution
6. `cmd/recall.sh` — cold-to-hot; removes symlink atomically; called by CLI and optionally by launcher hooks
7. `hooks/tracker.sh` — one-liner usage tracker; called from each launcher; touches `~/.modelstore/usage/{model-id}`
8. `bin/modelstore` — thin dispatcher; `exec`s cmd/ scripts; only used interactively; never called by cron

### Critical Pitfalls

1. **Race condition: migrating while model is in use** — check `fuser "$model_path"` before migration; schedule cron at 2 AM; keep the `mv + ln` window minimal by using atomic symlink swap (`ln -snf` or `mv -T`); verify with `lsof` checks
2. **Broken symlinks on cold drive unmount** — use `mountpoint -q` (not `test -d`) as the first check in every script touching cold paths; `status` command must flag dangling symlinks explicitly
3. **HF internal symlink breakage from splitting blobs/snapshots** — always migrate the entire `models--org--name/` directory as one atomic unit; never operate on subdirectories individually; verify post-migration with `find snapshots -xtype l`
4. **Ollama server caches manifest paths at startup** — check `systemctl is-active ollama` before any Ollama model migration; stop server, move, restart; or skip Ollama models if server is active
5. **Revert/partial-migration data loss via interrupt** — maintain a JSON state file recording intent-before-action and completion-after; make revert idempotent (re-runnable after interruption); never `rm -rf` without first confirming the path is not a symlink to a data directory

## Implications for Roadmap

Based on research, the dependency graph from FEATURES.md dictates a clear phase order: config must precede everything; adapters must precede core scripts; core scripts must precede cron; cron must precede polish features.

### Phase 1: Foundation — Config, Common Lib, and Project Structure

**Rationale:** Every other component sources config.sh and common.sh. Building them first means every subsequent phase starts from a working foundation. The mount-check and space-check utilities in common.sh gate migration and recall — they must exist before any data-moving code is written.
**Delivers:** `lib/config.sh`, `lib/common.sh`, `~/.modelstore/` state dir, `install.sh` skeleton, shellcheck CI setup
**Addresses:** Configurable retention period, drive mount validation, space-available check (all P1 table stakes)
**Avoids:** Hardcoded paths technical debt; `test -d` vs `mountpoint -q` mistake from PITFALLS.md

### Phase 2: Interactive Init and HuggingFace Adapter

**Rationale:** Init produces the config that all subsequent phases require. The HF adapter is simpler than Ollama (no blob reference counting) and validates the adapter pattern before tackling the more complex ecosystem. After this phase, manual HF model migration is possible even without automation.
**Delivers:** `cmd/init.sh` (with gum or read -p fallback), `lib/hf_adapter.sh`, `lib/notify.sh`, whole-directory-as-unit migration logic
**Addresses:** Interactive init wizard, HF symlink-based transparent access, filesystem tree preview
**Avoids:** HF internal symlink breakage (Pitfall 3), exFAT cold drive rejection, symlink loop on re-init

### Phase 3: Ollama Adapter and Usage Tracking

**Rationale:** Ollama is the more complex adapter (manifest parsing, blob reference counting, server state awareness). Usage tracking via tracker.sh must be built alongside adapters since the retention policy is inert without timestamps. Launcher hook integration completes the tracking signal.
**Delivers:** `lib/ollama_adapter.sh`, `hooks/tracker.sh`, `~/.modelstore/usage/` manifest directory, launcher hook one-liners
**Addresses:** Ollama two-ecosystem awareness, usage timestamp tracking, launcher hook integration
**Avoids:** Ollama blob sharing corruption (Anti-Pattern 5 from ARCHITECTURE.md), `atime` unreliability (Pattern 2), Ollama server restart pitfall (Pitfall 4)

### Phase 4: Core Migration and Recall

**Rationale:** With adapters and usage tracking in place, the migration and recall scripts can be built on solid ground. This is the core value delivery. flock-based concurrency control and atomic symlink swap belong here. The migration cron wrapper is built alongside migrate.sh.
**Delivers:** `cmd/migrate.sh`, `cmd/recall.sh`, `cron/migrate_cron.sh`, `cron/disk_check_cron.sh`, flock integration, atomic symlink replacement
**Addresses:** Migration cron, recall script, disk usage warning, drive mount validation (applied in practice)
**Avoids:** Race condition during migration (Pitfall 1), disk space estimation errors (Pitfall 6), silent cron failure (UX pitfall), notify-send from cron DBUS injection

### Phase 5: Status, Revert, and CLI Dispatcher

**Rationale:** Status and revert require both adapters and the usage tracking system to be functional. The CLI dispatcher is deliberately last — it's a thin router and adds no new logic. Revert's idempotency and state-file requirements make it the most careful piece of code in the project.
**Delivers:** `cmd/status.sh`, `cmd/revert.sh`, `bin/modelstore` dispatcher, JSON state file for interrupt-safe operations, `[HOT]`/`[COLD]`/`[BROKEN SYMLINK]` status labels
**Addresses:** Status command, full revert, single CLI entry point
**Avoids:** Revert data loss via interrupt (Pitfall 5), `rm -rf` through symlink, silent failure during revert

### Phase 6: Polish — Progress, Dry-run, Logging, Headless

**Rationale:** These features improve trust and debuggability but do not affect correctness. Adding them after the core is validated means they enhance a working system rather than complicating an unproven one.
**Delivers:** pv/rsync progress bars, `--dry-run` flag for migrate and revert, per-model migration audit log, NVIDIA Sync / headless `$DISPLAY` detection, recall-on-access launcher hook enhancement
**Addresses:** P2 features from FEATURES.md — progress bars, dry-run, audit trail, headless compatibility
**Avoids:** User trust issues (UX pitfalls: silent migration, no progress during revert)

### Phase Ordering Rationale

- Config and common lib precede all other code because they are sourced by every script — no script can be tested without them
- HF adapter precedes Ollama adapter because HF is structurally simpler and validates the pattern; tackling Ollama first risks discovering adapter design flaws only in the harder case
- Usage tracking must be built before migration cron is useful — without `~/.modelstore/usage/` timestamps, the stale-model detection query returns everything or nothing
- Revert is built after migration is proven correct — revert's correctness depends on understanding the exact state migration leaves behind
- CLI dispatcher is deliberately last; building it first creates an illusion of completeness while core scripts remain unwritten

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 3 (Ollama adapter):** Blob reference counting logic requires precise understanding of Ollama's manifest schema; consider a `/gsd:research-phase` to verify manifest JSON structure and confirm whether `OLLAMA_MODELS` env var approach is viable as an alternative to per-blob symlinking
- **Phase 4 (Migration cron):** DBUS session address injection for `notify-send` from cron has multiple known-broken variants; the specific `gnome-session` `/proc/environ` approach should be verified on the actual DGX Spark before committing to it
- **Phase 5 (Revert state file):** JSON state file format and interrupt-safety semantics are not fully specified in research; needs design work during planning

Phases with standard patterns (research-phase likely unnecessary):
- **Phase 1 (Foundation):** Key=value config file, bash sourcing patterns, shellcheck setup are completely standard; skip research-phase
- **Phase 2 (Init + HF adapter):** HF cache structure is fully documented in official HF docs; adapter logic follows known directory structure; skip research-phase
- **Phase 6 (Polish):** pv, rsync progress, dry-run flags, log appending are all well-documented standard patterns; skip research-phase

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | All core tools verified on DGX Spark host; versions confirmed; HF and Ollama structures from official docs |
| Features | HIGH | HF/Ollama official docs confirm what internal structure exists; feature set derived from verified filesystem behavior |
| Architecture | HIGH | Adapter pattern, atomic symlink swap, and dispatcher pattern are established idioms; cron integration patterns verified across multiple sources |
| Pitfalls | HIGH | Most pitfalls verified against official documentation and known filesystem behavior; a few notify-send/DBUS sources are MEDIUM confidence community-sourced |

**Overall confidence:** HIGH

### Gaps to Address

- **Ollama manifest JSON schema:** Research confirms blobs are referenced from manifests by digest but does not show the exact JSON field paths needed for parsing in `ollama_adapter.sh`. Verify with `cat ~/.ollama/models/manifests/registry.ollama.ai/library/<model>/latest` on the DGX before writing the adapter.
- **DBUS session address on DGX Spark (aarch64):** The `/proc/$(pgrep -u "$uid" gnome-session)/environ` approach for `notify-send` from cron is sourced from Ubuntu x86 community guides; the GNOME session on aarch64 DGX may use a different process name or DBus socket path. Test this on the actual machine during Phase 4.
- **Ollama `OLLAMA_MODELS` env var vs symlink approach:** Research mentions `OLLAMA_MODELS` as an alternative to per-blob symlinks but does not fully evaluate it. During Phase 3 planning, decide whether this is simpler than individual blob symlinks for the Ollama adapter.
- **Revert state file format:** Research recommends a state file for interrupt-safe revert but does not specify its schema. Design this during Phase 5 planning before writing `revert.sh`.
- **pv 1.10 vs 1.8.5 (apt):** The apt version (1.8.5) lacks `--query` and `--size @PATH`; upstream 1.10.4 has these. Research recommends upstream for best experience but does not specify a minimum required version for the Phase 6 progress feature. Determine during Phase 6 whether 1.8.5 is sufficient.

## Sources

### Primary (HIGH confidence)
- [HuggingFace Hub Cache Documentation](https://huggingface.co/docs/huggingface_hub/en/guides/manage-cache) — HF blob/snapshot/refs structure, symlink layout, migration unit
- [Ollama Model Storage Internals (DeepWiki)](https://deepwiki.com/ollama/ollama/4-model-management) — Ollama manifests and blob content-addressing
- [charmbracelet/gum releases](https://github.com/charmbracelet/gum/releases/tag/v0.17.0) — gum v0.17.0 arm64 apt install procedure
- [rsync man page (man7.org)](https://man7.org/linux/man-pages/man1/rsync.1.html) — `--remove-source-files`, `--info=progress2` flags
- [Atomic symlinks — rcrowley](https://rcrowley.org/2010/01/06/things-unix-can-do-atomically.html) — `mv -T` / `rename(2)` atomicity
- [Linux filesystem timestamps](https://www.howtogeek.com/517098/linux-file-timestamps-explained-atime-mtime-and-ctime/) — `relatime` behavior
- System tool versions verified directly on DGX Spark host: bash 5.2.21 (aarch64), rsync 3.2.7, pv 1.8.5, inotify-tools 3.22.6.0, shellcheck 0.9.0
- [ShellCheck official](https://www.shellcheck.net/) — linting capabilities and `-x` flag

### Secondary (MEDIUM confidence)
- [Ollama Model Storage article (Medium, Feb 2026)](https://medium.com/@enisbaskapan/how-ollama-stores-models-11fc47f48955) — Ollama blob/manifest structure (consistent with DeepWiki)
- [notify-send from cron (selivan.github.io)](https://selivan.github.io/2016/07/08/notify-send-from-cron-in-ubuntu.html) — DBUS env injection pattern
- [flock in cron (DEV Community)](https://dev.to/mochafreddo/understanding-the-use-of-flock-in-linux-cron-jobs-preventing-concurrent-script-execution-3c5h) — cron concurrency prevention pattern
- [pv + rsync progress (nixCraft)](https://www.cyberciti.biz/faq/show-progress-during-file-transfer/) — pv pipeline pattern
- [Ollama FAQ](https://docs.ollama.com/faq) — OLLAMA_MODELS env var for custom models directory
- [HF issue #2038](https://github.com/huggingface/huggingface_hub/issues/2038) — known file lock behavior during downloads (confirms `.lock` file check before migration)

---
*Research completed: 2026-03-21*
*Ready for roadmap: yes*
