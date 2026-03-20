# Stack Research

**Domain:** Tiered ML model storage system — bash scripts on Linux aarch64
**Researched:** 2026-03-21
**Confidence:** HIGH (most tools are system utilities with stable, well-documented behavior)

---

## Recommended Stack

### Core Technologies

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| Bash | 5.2.21 (on host) | Script runtime for all modelstore components | Already present; constraint requires no Python outside containers. Bash 5.x provides `mapfile`, associative arrays, and `[[ ]]` — all needed. |
| rsync | 3.2.7 (on host) | Atomic file migration between hot and cold tiers | `--remove-source-files` makes it the safest atomic move tool for large ML model files. `--info=progress2` gives per-transfer progress without per-file noise. Handles sparse files, preserves timestamps, and resumes interrupted transfers. Do NOT use `mv` — it fails across filesystems. |
| pv | 1.10.4 (upstream); 1.8.5 available in apt | Progress bar for data pipelines | Inserts into any pipeline between two commands to show throughput, ETA, and completion percentage. Version 1.10+ adds `--query` to monitor a running pv from another process and `--size @PATH` for directory-level size estimation — use upstream version for best experience. |
| flock | util-linux (on host) | Prevent concurrent cron job execution | Built into util-linux, always present on Linux. Mandatory for migration cron: `flock -n /var/lock/modelstore.lock` prevents a slow migration from overlapping with the next scheduled run. File-descriptor-based locking releases automatically on crash. |
| inotify-tools / inotifywait | 3.22.6.0 (in apt) | Filesystem event monitoring | Kernel-level inotify API wrapper. Use for detecting when a symlink target is accessed (recall trigger) without polling. Event-driven — no busy-wait loop consuming CPU. `inotifywait -e access` fires on file open. |
| notify-send | libnotify (on host) | Desktop disk-usage alerts | Already present on GNOME session. Best delivery mechanism for 98% disk usage warnings — more visible than syslog on a desktop workstation. Use `DBUS_SESSION_BUS_ADDRESS` passthrough when called from cron (no TTY). |

### Supporting Libraries / Tools

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| gum (charmbracelet) | v0.17.0 | Interactive init prompts, filesystem tree preview, confirm dialogs | Use in `modelstore init` and `modelstore revert` for TTY-interactive flows only. Do NOT call from cron scripts or Sync hooks. Install via Charm apt repo (supports arm64). |
| shellcheck | 0.9.0 (apt) | Static analysis and linting for all bash scripts | Run in CI/pre-commit on every `.sh` file. Catches quoting bugs, unbound variable references, and POSIX portability issues before they corrupt model data. |
| findutils (`find`) | system | Locate models by last-access time for stale detection | Use `find ~/.cache/huggingface/hub/ -maxdepth 4 -name "*.safetensors" -atime +14` to find stale models. The `-atime` flag tracks last access — pairs with the usage-tracker `touch` approach as a fallback. |
| stat / touch | coreutils (system) | Read and write per-model timestamps | `stat --format="%X"` reads last-access epoch. `touch -a` updates atime on model recall. Used by usage tracker hooks in launcher scripts. |
| df | coreutils (system) | Disk usage reporting for space checks and status display | `df --output=pcent,avail,target` gives machine-parseable output. Use in pre-migration space check and `modelstore status`. |
| ln | coreutils (system) | Create and replace symlinks | `ln -sfn` atomically replaces a symlink target in one operation — critical for the hot-to-cold transition. Use `-sf` not `ln -s` to avoid "file exists" errors on re-migration. |

### Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| shellcheck | Linting and static analysis | `shellcheck -x` follows `source` directives; configure per-file `# shellcheck source=lib.sh`. Integrate into git pre-commit hook. |
| bats-core | Bash unit testing | Optional but valuable for testing migration logic without touching real model data. Install via `apt install bats` or from GitHub releases. |

---

## Installation

```bash
# Already on host — no install needed
# rsync 3.2.7, flock, find, stat, df, ln, touch, notify-send, bash 5.2

# Install pv (progress bars) and inotify-tools (filesystem events)
sudo apt install pv inotify-tools

# Install shellcheck (linting)
sudo apt install shellcheck

# Install gum (interactive init UI) — requires Charm apt repo for arm64
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
sudo apt update && sudo apt install gum

# Optional: bats for testing
sudo apt install bats
```

---

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| rsync with `--remove-source-files` | `mv` across filesystems | Never — `mv` fails across filesystems (internal NVMe to external NVMe are separate mountpoints). Only use `mv` for same-filesystem moves. |
| rsync `--info=progress2` | pv piped to rsync | Use pv when you need a persistent progress bar that doesn't scroll (pv overwrites in-place). Use `--info=progress2` when logging to file or when pv is not installed. |
| flock | PID file (`/var/run/modelstore.pid`) | PID files work but require manual cleanup on crash. flock releases automatically when the process exits — strictly safer for cron. |
| inotifywait | Polling loop with `sleep` | Only use polling if inotify is unavailable (e.g., FUSE mounts). inotify is zero-CPU when idle and sub-millisecond response. |
| gum for init UI | `read -p` prompts | Use `read -p` if gum is unavailable or script runs in non-TTY context. gum is strictly additive — its absence must not break non-interactive flows. |
| Key=value config file (`~/.config/modelstore/config`) | INI parser | Key=value pairs parsed with `source` or `grep`/`awk` are simpler than INI in pure bash. No external parser needed. Format: `HOT_PATH=~/.cache/huggingface/hub`. |
| `notify-send` | Email via `sendmail` | Email is appropriate on headless servers. This system targets a GNOME desktop (DGX Spark) — desktop notifications are immediately visible. |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `mv` for cross-filesystem migration | Fails with "Invalid cross-device link" between internal NVMe and external NVMe — they are separate block devices with separate mountpoints | `rsync -a --remove-source-files` |
| Python for core scripts | Constraint from PROJECT.md: scripts run on host outside containers; Python version and venv state are unreliable in that context | Bash with coreutils |
| `cp` then manual `rm` for migration | Non-atomic: if interrupted after `cp` but before `rm`, you have duplicate data and no symlink | `rsync --remove-source-files` only deletes source after successful transfer |
| Hard links across filesystems | Hard links require source and destination to be on the same filesystem. Internal NVMe and external NVMe are different devices. | Symlinks (`ln -s`) — work across any filesystems |
| `autotier` (FUSE-based tiering daemon) | Heavyweight daemon, adds FUSE layer, requires kernel module support, introduces latency. This project needs a targeted bash script, not a general-purpose filesystem daemon. | Direct bash scripts with rsync and symlinks |
| bcache / dm-cache | Kernel block-layer cache requires partitioning and reboots to configure; completely destructive to repartition on a running DGX Spark. | Symlink-based application-level tiering |
| `inotifywait` for cron-triggered migration | inotify is event-driven and not suited for time-based "check all models once a day" logic. | `cron` + `find -atime` for scheduled migration |
| Absolute paths in HuggingFace `snapshots/` symlinks | HuggingFace hub uses relative symlinks by design so the cache directory can be moved. If you reconstruct symlinks with absolute paths after migration, moving the cache will break them. | Preserve relative symlinks exactly as HuggingFace created them; migrate the entire model directory as a unit. |

---

## Stack Patterns by Variant

**For migration cron job (no TTY, no interactive):**
- Use rsync + flock + rsync `--info=progress2` logging to file
- Do NOT use gum (requires TTY)
- Pass `DBUS_SESSION_BUS_ADDRESS` to enable notify-send from cron
- Pattern: `flock -n /var/lock/modelstore-migrate.lock rsync -a --remove-source-files --info=progress2 "$SRC/" "$DEST/"`

**For interactive init / revert (TTY present):**
- Use gum for `choose`, `confirm`, `spin`, and `input` components
- Fall back gracefully to `read -p` if `command -v gum` fails
- Show rsync progress via pv or `--info=progress2` to terminal

**For launcher hooks (vLLM, Ollama, Unsloth — may or may not have TTY):**
- Use only `touch -a` (update atime) — zero dependencies
- If model is a symlink pointing to cold tier: trigger recall inline or log for async recall
- No gum, no notify-send, no pv — launcher hooks must be fast and silent

**For HuggingFace cache migration:**
- Migrate the entire `models--{org}--{model}/` directory as a unit
- The directory contains `blobs/`, `snapshots/` (with relative symlinks), and `refs/`
- Preserve relative symlinks: use `rsync -a --links` (default) — do NOT dereference them
- After migration, create one symlink at the original `models--{org}--{model}/` location pointing to cold store

**For Ollama cache migration:**
- Ollama stores models as content-addressed blobs in `~/.ollama/models/blobs/` referenced by SHA256
- Manifests in `~/.ollama/models/manifests/` reference blob hashes — no symlinks in the internal structure
- Migrate the full `~/.ollama/models/` subtree for a given model's blobs and manifest together
- Symlink the blob files individually, or symlink the entire models directory (simpler)

---

## Version Compatibility

| Package | Compatible With | Notes |
|---------|-----------------|-------|
| rsync 3.2.7 | `--info=progress2`, `--remove-source-files`, `-a --links` | All needed flags present since rsync 3.1.0. 3.2.x on this host is current. |
| pv 1.8.5 (apt) | Basic progress bars | Lacks `--query` and `--size @PATH` from 1.10. Sufficient for MVP; upgrade to 1.10.4 from upstream for `--query` support. |
| bash 5.2.21 | Associative arrays, `mapfile`, `[[ ]]`, process substitution | All bash 5.x features available. Do not use bash 4-only workarounds. |
| inotify-tools 3.22.6.0 | `-e access`, `-m` (monitor mode), `-r` (recursive) | Stable API; all needed events present. |
| gum 0.17.0 | `gum choose`, `gum confirm`, `gum spin`, `gum input`, `gum file` | arm64 binary in Charm apt repo. GPG key must be installed first (known issue: #377). |
| flock (util-linux) | `-n` (nonblocking), `-e` (exclusive), lock on file descriptor | Built into util-linux which ships with every Ubuntu/Debian. No version concern. |

---

## Sources

- [ivarch.com — Pipe Viewer (pv)](https://www.ivarch.com/programs/pv.shtml) — verified version 1.10.4, feature list (HIGH confidence)
- [HuggingFace — Understand caching (official docs)](https://huggingface.co/docs/huggingface_hub/en/guides/manage-cache) — verified relative symlink architecture in `snapshots/` (HIGH confidence)
- [Ollama model storage — Medium, Feb 2026](https://medium.com/@enisbaskapan/how-ollama-stores-models-11fc47f48955) — blobs/manifests structure, SHA256 addressing (MEDIUM confidence — secondary source, but consistent with DeepWiki)
- [charmbracelet/gum releases — GitHub](https://github.com/charmbracelet/gum/releases/tag/v0.17.0) — confirmed v0.17.0 latest, arm64 apt install procedure (HIGH confidence)
- [rsync man page — man7.org](https://man7.org/linux/man-pages/man1/rsync.1.html) — `--info=progress2`, `--remove-source-files` flags (HIGH confidence)
- [flock — DEV Community](https://dev.to/mochafreddo/understanding-the-use-of-flock-in-linux-cron-jobs-preventing-concurrent-script-execution-3c5h) — cron concurrency pattern (MEDIUM confidence)
- [inotifywait — linuxbash.sh](https://www.linuxbash.sh/post/monitoring-file-changes-with-inotifywait) — `-m -e access` usage pattern (MEDIUM confidence)
- [pv progress with rsync — nixCraft](https://www.cyberciti.biz/faq/show-progress-during-file-transfer/) — pv + rsync pipeline pattern (MEDIUM confidence)
- [ShellCheck — official](https://www.shellcheck.net/) — linting capabilities (HIGH confidence)
- System tool versions verified directly on DGX Spark host: bash 5.2.21 (aarch64), rsync 3.2.7, pv 1.8.5 (apt), inotify-tools 3.22.6.0, shellcheck 0.9.0

---

*Stack research for: tiered ML model storage system on DGX Spark (aarch64 Linux)*
*Researched: 2026-03-21*
