# Feature Research

**Domain:** Tiered model storage / model cache management CLI tool
**Researched:** 2026-03-21
**Confidence:** HIGH (core storage mechanics from official HF/Ollama docs; CLI patterns from established tooling)

## Feature Landscape

### Table Stakes (Users Expect These)

Features users assume exist. Missing these = product feels incomplete.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Symlink-based transparent access | HF and Ollama both use symlinks internally; all model consumers (vLLM, transformers, Ollama) resolve symlinks transparently — if tiering breaks this contract, models fail silently | MEDIUM | Must preserve HF blob/snapshot/refs hierarchy. Ollama uses flat blobs + manifests. Symlinks must be relative-path-safe or absolute depending on filesystem boundary. |
| Drive mount validation before any symlink operation | Broken symlinks caused by unmounted cold drive = silent model load failures; this is the #1 data-loss/corruption risk | LOW | `mountpoint -q /path` check before every migration and recall. Refuse with clear error if cold drive is absent. |
| Usage timestamp tracking per model | Migration decisions require knowing when a model was last used; without this the retention policy has no signal | LOW | Touch a `.last_used` file or update mtime on first load via launcher hooks. Per-model, not per-blob — track at the model/repo level. |
| Configurable retention period | Default 14 days is a guess; users may want 7 days on a small hot drive or 60 days if they use models infrequently | LOW | Single config value in `~/.config/modelstore/config` or alongside the tool. Validated on init. |
| Space-available check before migration | If cold drive is nearly full, migrating would corrupt the destination and leave the source in an inconsistent state | LOW | `df -h` / `stat --file-system --format=%a` check against model size before any `mv`. Abort with error if insufficient. |
| Status command: what's on each tier | Users need to know which models are hot/cold, sizes, last-used times, and available space without reading raw filesystem | MEDIUM | Table output: model name, tier (hot/cold/symlinked), size, last_used, days_until_migration. Aggregated totals per drive. |
| Full revert (undo all tiering) | Users need a safe exit path: if drives change or the tool is abandoned, all models must be recoverable to their original locations without data loss | MEDIUM | Move all cold-tier models back to hot, remove all symlinks, restore original directory structure. Non-destructive: never delete. |
| Single CLI entry point with subcommands | Established pattern for sysadmin tools (git, docker, kubectl); users expect `modelstore <subcommand>` not a collection of ad-hoc scripts | LOW | `modelstore init`, `status`, `migrate`, `recall`, `revert`. Each subcommand dispatches to an individual script for cron/hook compatibility. |
| Disk usage warning at threshold | If either drive exceeds 98% capacity without warning, users discover the problem only when a download or migration fails — too late | LOW | Cron-invoked check using `df`. Threshold configurable (default 98%). Desktop notification via `notify-send` on GNOME. |
| Hook existing launchers for usage tracking | Without launcher integration, the `.last_used` timestamps are never updated and the retention policy fires on models currently in active use | LOW | Prepend one-liner `modelstore track <model>` call to vLLM, eval-toolbox, data-toolbox, Unsloth, Ollama launcher scripts. |

### Differentiators (Competitive Advantage)

Features that set the product apart. Not required, but valuable.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Interactive init wizard with filesystem tree preview | Existing tools (HF CLI, Ollama) offer no storage placement guidance; a guided setup that shows current usage and lets the user pick mount points reduces misconfiguration on first run | MEDIUM | Use `gum` (Charm) or plain `select` + `read` for drive selection. Show `df -h` and `tree -L 2` output inline. Confirm folder creation before writing anything. Avoids needing external TUI dependency if `gum` is absent. |
| Progress bars during migration and revert | Moving multi-GB model files with no feedback looks like a hang; `pv` or rsync `--info=progress2` makes the operation feel safe and inspectable | LOW | Use `pv` if available, fall back to rsync `--info=progress2`, fall back to silent `mv` with a spinner. Detect capability at runtime. |
| Reinit with live migration (reconfigure drives) | If the user wants to swap hot/cold drive assignments or replace a drive, they need a path that moves all models to the new layout without a full revert+init cycle | HIGH | Computes a diff between current config and desired config, migrates only what changed. Complexity: must handle partial migration on failure, rollback logic. |
| Two-ecosystem awareness (HF + Ollama) | Tools like `huggingface-cli` only manage HF cache; Ollama's blob+manifest structure requires different traversal logic. Supporting both in one tool is unique for DGX Spark workflows | MEDIUM | HF: traverse `models--*/blobs/` for actual data, measure via blob sizes, symlink at snapshot level. Ollama: traverse `blobs/sha256-*` and `manifests/`, measure blob sizes, symlink entire blobs dir or manifests dir. Must handle HF's relative symlinks correctly when moving blobs. |
| Recall-on-access (automatic hot promotion) | Users shouldn't need to run `modelstore recall` manually before launching a model; launcher hooks can detect cold-tier models and recall transparently before the loader runs | MEDIUM | Launcher hook checks if model path is a symlink pointing to cold tier; if so, runs recall before exec. Adds latency to first launch after cold migration — user should be informed via notify-send. |
| Dry-run mode for migrate and revert | Allows users to preview exactly what would be moved without committing; critical for trust-building with a tool that moves multi-GB files | LOW | `--dry-run` flag: print planned operations with sizes, space deltas, symlink targets. No filesystem writes. |
| NVIDIA Sync / headless compatibility | Scripts invoked via Sync have no TTY; interactive prompts must be skipped, output must be log-friendly, and `notify-send` must target the correct DBUS session | LOW | Detect `$DISPLAY`/`$DBUS_SESSION_BUS_ADDRESS`; skip TUI prompts and fall back to non-interactive defaults when not set. Log to file when no TTY. |
| Per-model migration log / audit trail | When troubleshooting why a model is cold, users want a timestamped record of migration and recall events | LOW | Append-only log at `~/.local/share/modelstore/migrations.log`. Fields: timestamp, model, action (migrate/recall/init/revert), source, destination, size. |

### Anti-Features (Commonly Requested, Often Problematic)

Features that seem good but create problems.

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Automatic model downloading / pulling | "While you're managing storage, also download models for me" | Out of scope — HF and Ollama already have download tools; adding download logic duplicates functionality and introduces auth complexity, network error handling, and resume logic that have nothing to do with tiering | Let `huggingface-cli download` and `ollama pull` handle downloads; modelstore only manages what's already on disk |
| Per-model pin (always keep on hot) | "Some models I always want on the hot drive" | Introduces a per-model config database, UI to manage pins, and exception logic in every migration code path. Complexity multiplies for little gain given the two-tier design | Set a very long retention period (e.g., 3650 days) globally if the user rarely wants migration, or use a longer cold threshold for the entire store |
| RAID / multi-drive pooling | "Use all my drives as one hot pool" | Requires volume management (LVM, ZFS, mdadm), filesystem expertise, and dramatically changes the architecture from two-tier symlink to block-level storage. Scope explosion | Document that external NVMe is the one cold tier; users who need pooling should set up LVM before running init |
| Cloud storage tiering (S3, GCS) | "Move models to S3 when cold" | Network latency on recall makes models unusable for inference workflows. Auth credential management adds attack surface. Recall could take minutes or hours for multi-GB models | Cloud tier is architecturally incompatible with inference workloads; document this explicitly and suggest dedicated backup tools (rclone) for archival |
| Interactive TUI for daily migration decisions | "Show me each model and ask hot/cold before migrating" | Daily cron migration must be headless and non-interactive. A TUI for this inverts the automation value proposition | Provide `modelstore status` for manual review and `modelstore migrate --dry-run` for preview; let the cron run unattended |
| Model deduplication across HF and Ollama | "If HF and Ollama both have the same base weights, store once" | HF and Ollama use different content-addressing schemes (SHA256 of file content vs. SHA256 of OCI-style layers); cross-ecosystem dedup requires re-hashing all blobs and building a new index. Risk of data corruption outweighs storage savings | Each ecosystem manages its own dedup internally (HF blobs are already deduplicated within a repo; Ollama blobs are deduplicated across models sharing layers) |

## Feature Dependencies

```
[Usage Timestamp Tracking]
    └──requires──> [Launcher Hook Integration]
                       └──enables──> [Recall-on-Access]

[Interactive Init Wizard]
    └──produces──> [Config File (hot/cold paths, retention period)]
                       └──required by──> [Migration Cron]
                       └──required by──> [Recall Script]
                       └──required by──> [Status Command]
                       └──required by──> [Revert]
                       └──required by──> [Reinit/Reconfigure]

[Drive Mount Validation]
    └──gates──> [Migration Cron]
    └──gates──> [Recall Script]
    └──gates──> [Revert]

[Space-Available Check]
    └──gates──> [Migration Cron]
    └──gates──> [Recall Script]

[Migration Cron]
    └──requires──> [Symlink-Based Transparent Access]
    └──requires──> [Usage Timestamp Tracking]
    └──requires──> [Drive Mount Validation]
    └──requires──> [Space-Available Check]

[Revert]
    └──requires──> [Drive Mount Validation] (cold drive must be mounted to read from it)
    └──conflicts──> [Migration Cron running concurrently] (lock file needed)

[Reinit/Reconfigure]
    └──requires──> [Interactive Init Wizard] (for new config)
    └──requires──> [Migration Cron logic] (to move models to new layout)
    └──conflicts──> [Revert running concurrently]

[Progress Bars]
    └──enhances──> [Migration Cron]
    └──enhances──> [Recall Script]
    └──enhances──> [Revert]
    └──enhances──> [Reinit/Reconfigure]

[Disk Usage Warning]
    └──requires──> [Config File] (to know which drives to monitor)
    └──independent of──> [Migration Cron] (separate cron job or combined)
```

### Dependency Notes

- **Config File is the backbone:** Every operational feature depends on the config produced by init. Init must be Phase 1.
- **Drive mount validation gates all data movement:** Must be implemented as a shared function in `lib.sh` before any migration, recall, or revert code is written.
- **Usage tracking requires launcher hooks:** The retention policy is inert without timestamps. Launchers must be hooked before migration cron is useful.
- **Revert and migration must not run concurrently:** A simple lock file (`/tmp/modelstore.lock`) prevents race conditions when both are triggered.
- **Recall-on-access is an enhancement of recall, not a replacement:** Manual `modelstore recall <model>` must work standalone; the launcher hook is additive.

## MVP Definition

### Launch With (v1)

Minimum viable product — what's needed to validate the concept.

- [ ] Interactive init wizard — selects hot/cold paths, validates mounts, creates config, creates directories, no data moved
- [ ] Usage timestamp tracking + launcher hooks — `modelstore track <model>` called from each launcher; touches `.last_used` file
- [ ] Migration cron script — reads config, checks mount + space, finds stale models (> retention days), `mv` + creates symlinks
- [ ] Recall script — detects cold-tier model, checks mount + space, `mv` back, replaces symlink, resets timestamp
- [ ] Status command — table of all models: tier, size, last_used, days_until_migration; drive space summary
- [ ] Drive mount validation (shared lib function) — prerequisite for migration and recall
- [ ] Space-available check (shared lib function) — prerequisite for migration and recall
- [ ] Disk usage warning cron — `notify-send` when either drive > 98%
- [ ] Full revert — moves all cold models back, removes all symlinks; non-destructive

### Add After Validation (v1.x)

Features to add once core is working.

- [ ] Progress bars (pv / rsync fallback) — add after migration/recall is confirmed correct; visual polish
- [ ] Dry-run mode for migrate and revert — add when users start asking "what would happen if..."
- [ ] Per-model migration log / audit trail — add when debugging needs arise
- [ ] Recall-on-access via launcher hooks — add after manual recall is stable and tested
- [ ] NVIDIA Sync / headless compatibility hardening — add when Sync integration is being wired up

### Future Consideration (v2+)

Features to defer until product-market fit is established.

- [ ] Reinit/reconfigure with live migration — high complexity; defer until user actually needs to swap drives
- [ ] Two-ecosystem awareness improvements — deeper HF blob-level analysis (tracking individual blob last_used across shared revisions); defer until simpler model-level tracking proves insufficient
- [ ] Interactive deletion TUI (like huggingface-cli delete-cache) — useful but not needed for core tiering workflow

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Interactive init wizard | HIGH | MEDIUM | P1 |
| Drive mount validation | HIGH | LOW | P1 |
| Usage timestamp tracking | HIGH | LOW | P1 |
| Launcher hook integration | HIGH | LOW | P1 |
| Migration cron | HIGH | MEDIUM | P1 |
| Recall script | HIGH | MEDIUM | P1 |
| Status command | HIGH | MEDIUM | P1 |
| Space-available check | HIGH | LOW | P1 |
| Disk usage warning | MEDIUM | LOW | P1 |
| Full revert | HIGH | MEDIUM | P1 |
| Progress bars | MEDIUM | LOW | P2 |
| Dry-run mode | MEDIUM | LOW | P2 |
| Recall-on-access (launcher) | MEDIUM | MEDIUM | P2 |
| Per-model migration log | LOW | LOW | P2 |
| Headless/Sync compatibility | MEDIUM | LOW | P2 |
| Reinit/reconfigure | MEDIUM | HIGH | P3 |
| Interactive deletion TUI | LOW | MEDIUM | P3 |

**Priority key:**
- P1: Must have for launch
- P2: Should have, add when possible
- P3: Nice to have, future consideration

## Competitor Feature Analysis

| Feature | huggingface-cli cache | Ollama built-in | modelstore (our approach) |
|---------|----------------------|-----------------|--------------------------|
| Cache inspection / status | `hf cache ls` with size, last_accessed, refs | `ollama list` (name, size, modified) | Unified status across both ecosystems: tier, size, last_used, days_until_migration |
| Cache deletion | `hf cache rm` / `hf cache prune`; interactive TUI | `ollama rm <model>` | Not a deletion tool — tiering only; deletion left to native tools |
| Automatic tiering / migration | None — manual deletion only | None — single flat directory | Core value: automated hot→cold migration based on LRU retention policy |
| Symlink management | Internal only (blobs→snapshots within cache) | Not exposed | Cross-filesystem symlinks: hot drive ↔ cold drive |
| Drive space monitoring | None | None | cron-based `notify-send` warnings at configurable threshold |
| Recall / hot promotion | None — re-download only | None — re-download only | `modelstore recall <model>` moves from cold back to hot without re-downloading |
| Interactive setup | None | None | Guided init wizard with drive selection and directory confirmation |
| Cron / headless operation | Partial (no cron integration) | None | First-class: individual scripts designed for cron and Sync invocation |

## Sources

- [HuggingFace Hub Cache Management (official docs)](https://huggingface.co/docs/huggingface_hub/en/guides/manage-cache) — HIGH confidence
- [Ollama Model Storage: Blobs and Manifests (Medium, 2026)](https://medium.com/@enisbaskapan/how-ollama-stores-models-11fc47f48955) — MEDIUM confidence
- [Ollama Model Management (DeepWiki)](https://deepwiki.com/ollama/ollama/4-model-management) — MEDIUM confidence
- [huggingface_hub RFC: Revamp hf cache (GitHub, Oct 2025)](https://github.com/huggingface/huggingface_hub/issues/3432) — HIGH confidence (identifies known UX gaps in existing tools)
- [pv + rsync progress bar patterns (nixCraft, Baeldung)](https://www.cyberciti.biz/faq/show-progress-during-file-transfer/) — HIGH confidence
- [gum interactive CLI (Charm)](https://www.x-cmd.com/pkg/gum/) — MEDIUM confidence
- [Cache replacement policies (Wikipedia)](https://en.wikipedia.org/wiki/Cache_replacement_policies) — HIGH confidence for LRU theory

---
*Feature research for: Tiered model storage / model cache management CLI (DGX Spark)*
*Researched: 2026-03-21*
