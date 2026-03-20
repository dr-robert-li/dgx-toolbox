# Architecture Research

**Domain:** Tiered local storage system for ML model caches (HuggingFace + Ollama)
**Researched:** 2026-03-21
**Confidence:** HIGH

## Standard Architecture

### System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Entry Layer                               │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌───────────────┐  ┌──────────────────────┐   │
│  │  modelstore │  │  Cron jobs    │  │  Launcher hooks      │   │
│  │  CLI        │  │  (migrate,    │  │  (vLLM, eval-toolbox,│   │
│  │  dispatcher │  │   disk-check) │  │   Unsloth, Ollama)   │   │
│  └──────┬──────┘  └───────┬───────┘  └──────────┬───────────┘   │
│         │                 │                     │               │
├─────────┴─────────────────┴─────────────────────┴───────────────┤
│                        Core Logic Layer                          │
├──────────────┬─────────────────────┬────────────────────────────┤
│  ┌───────────┴──────┐  ┌───────────┴──────┐  ┌─────────────┐   │
│  │  config.sh       │  │  tracker.sh      │  │  notify.sh  │   │
│  │  (read/write     │  │  (touch manifest │  │  (wrap      │   │
│  │   ~/.modelstore/ │  │   on model use)  │  │  notify-send│   │
│  │   config)        │  │                  │  │  for cron)  │   │
│  └───────────┬──────┘  └───────────┬──────┘  └──────┬──────┘   │
│              │                     │                │           │
│  ┌───────────┴──────┐  ┌───────────┴──────┐         │           │
│  │  migrate.sh      │  │  recall.sh       │         │           │
│  │  (hot→cold,      │  │  (cold→hot,      │         │           │
│  │   place symlink) │  │   remove symlink)│         │           │
│  └───────────┬──────┘  └───────────┬──────┘         │           │
│              │                     │                │           │
├──────────────┴─────────────────────┴────────────────┴───────────┤
│                       Storage Abstraction Layer                  │
├────────────────────────────┬────────────────────────────────────┤
│  ┌─────────────────────┐   │   ┌──────────────────────────┐     │
│  │  hf_adapter.sh      │   │   │  ollama_adapter.sh       │     │
│  │  (knows HF cache    │   │   │  (knows Ollama blob/      │     │
│  │   blob/snapshot     │   │   │   manifest structure;    │     │
│  │   layout; lists,    │   │   │   lists, moves, symlinks)│     │
│  │   moves, symlinks)  │   │   │                          │     │
│  └─────────────────────┘   │   └──────────────────────────┘     │
├────────────────────────────┴────────────────────────────────────┤
│                        Physical Storage Layer                    │
├────────────────────────────┬────────────────────────────────────┤
│  HOT STORE (internal NVMe) │  COLD STORE (external NVMe)        │
│  ~/.cache/huggingface/hub/ │  /media/robert_li/modelstore-1tb/  │
│  ~/.ollama/models/         │    huggingface/hub/                 │
│                            │    ollama/models/                   │
└────────────────────────────┴────────────────────────────────────┘
```

### Component Responsibilities

| Component | Responsibility | Communicates With |
|-----------|---------------|-------------------|
| `modelstore` CLI dispatcher | Parse argv, route to subcommand scripts, return exit codes | All subcommand scripts |
| `config.sh` | Read/write `~/.modelstore/config` (hot/cold paths, retention days, cron time); validate drive mounts | All other scripts (sourced) |
| `hf_adapter.sh` | Enumerate HF model directories (`models--*`), identify blob vs snapshot vs refs layout, perform moves and symlink operations for HF models | `migrate.sh`, `recall.sh`, `tracker.sh` |
| `ollama_adapter.sh` | Enumerate Ollama manifests under `manifests/`, locate referenced blobs under `blobs/`, perform moves and symlink operations for Ollama models | `migrate.sh`, `recall.sh`, `tracker.sh` |
| `tracker.sh` | Touch a per-model timestamp file in `~/.modelstore/usage/` when a model is loaded; called by launcher hooks | Called from launcher scripts |
| `migrate.sh` | Find models not accessed in N days; check destination space; move data to cold store; place relative symlinks; update usage manifest | Called by cron and `modelstore migrate` |
| `recall.sh` | Detect symlink at hot path; move cold data back; replace symlink with real directory; reset usage timestamp | Called by `modelstore recall` and optionally by launcher hooks |
| `notify.sh` | Wrapper for `notify-send` that sets required env vars (`DBUS_SESSION_BUS_ADDRESS`, `DISPLAY`, `XDG_RUNTIME_DIR`) so notifications work from cron context | Called from `migrate.sh` disk-check cron |
| Cron entries | Two crontab lines: daily migration at configurable hour; daily disk-usage check. Both call individual scripts (not the CLI dispatcher) | `migrate.sh`, disk_check.sh |
| Launcher hooks | One-liner additions to existing vLLM/eval-toolbox/Unsloth/Ollama launcher scripts that call `tracker.sh` with the model path before invoking the tool | `tracker.sh` |

## Recommended Project Structure

```
modelstore/
├── bin/
│   └── modelstore              # CLI dispatcher: sources lib, routes $1 to subcommand
├── lib/
│   ├── config.sh               # Config read/write helpers (sourced by all scripts)
│   ├── hf_adapter.sh           # HuggingFace cache layout logic (sourced)
│   ├── ollama_adapter.sh       # Ollama blob/manifest layout logic (sourced)
│   ├── notify.sh               # notify-send wrapper with cron-safe env setup
│   └── common.sh               # Shared: logging, mount check, space check helpers
├── cmd/
│   ├── init.sh                 # Interactive setup: select paths, create dirs, write config
│   ├── migrate.sh              # Migration worker: hot→cold with symlinks
│   ├── recall.sh               # Recall worker: cold→hot, remove symlink
│   ├── status.sh               # Report: both tiers, sizes, timestamps, space
│   └── revert.sh               # Full revert: move everything hot, remove all symlinks
├── cron/
│   ├── migrate_cron.sh         # Thin cron wrapper: sources config, calls migrate.sh
│   └── disk_check_cron.sh      # Disk usage check: calls notify.sh if >98%
├── hooks/
│   └── tracker.sh              # Usage tracker: touch ~/.modelstore/usage/<model-id>
└── install.sh                  # Installs crontab entries, creates ~/.modelstore/ state dir
```

### Structure Rationale

- **bin/**: Single entry point for interactive use; not used by cron or hooks (avoids TTY dependency)
- **lib/**: Sourced libraries only — no executable logic, no side effects on source
- **cmd/**: One file per subcommand; each is independently executable so cron and Sync can invoke them directly without going through the CLI dispatcher
- **cron/**: Thin wrappers that only set up environment and delegate; keeps cron lines simple and testable
- **hooks/**: Launcher integration is a single script with a clear contract (receive model path, touch timestamp)

## Architectural Patterns

### Pattern 1: Adapter Per Cache Ecosystem

**What:** Each cache format (HuggingFace, Ollama) gets its own adapter script that encapsulates all knowledge of that format's internal directory structure. The migration and recall scripts call only adapter functions — never hardcoded paths.

**When to use:** Always. HF and Ollama have fundamentally different layouts; mixing this knowledge into migrate.sh creates a maintenance trap.

**Trade-offs:** Small overhead of an extra source call; payoff is that adding a third ecosystem (e.g., `~/.cache/torch/`) means writing one new adapter rather than modifying core logic.

**HF adapter key knowledge:**
```
~/.cache/huggingface/hub/
  models--{org}--{name}/
    blobs/          ← actual content, addressed by SHA256
    refs/           ← maps branch names to commit hashes (tiny text files)
    snapshots/
      {commit-hash}/
        {filename}  ← symlinks pointing to ../../blobs/{hash}
```
The unit of migration is the entire `models--{org}--{name}/` directory. The adapter moves this directory to cold store and creates a symlink at the original hot path. Because snapshots already use relative symlinks to blobs (both within the same model dir), internal symlinks remain valid after the directory moves as long as the internal relative structure is preserved.

**Ollama adapter key knowledge:**
```
~/.ollama/models/
  manifests/
    registry.ollama.ai/library/{model}/{tag}  ← JSON manifest
  blobs/
    sha256-{hex}                              ← blob files
```
The unit is more complex: a manifest JSON references multiple blobs by digest. The adapter must parse the manifest to find all referenced blobs, move both manifest and blobs, and create symlinks for both paths. Ollama resolves blobs by reading manifests, so both must redirect.

### Pattern 2: Manifest-Based Usage Tracking (Not atime)

**What:** Maintain a separate usage manifest directory at `~/.modelstore/usage/` where each model's last-access timestamp is stored as a plain file: touching `~/.modelstore/usage/{model-id}` is the record of use.

**When to use:** Always. Do not rely on filesystem `atime` for usage tracking.

**Why not atime:**
- ext4 mounts default to `relatime`, which only updates atime once per 24-hour window — insufficient granularity for detecting same-day use
- The cold store (external NVMe) may have different mount options; atime behavior is filesystem-instance-specific
- HuggingFace snapshot paths are symlinks; `atime` on a symlink tracks when the symlink itself was accessed, not the blob it targets — this is unreliable for tracking "model was loaded"
- Manifest files are controllable: the hook can write them regardless of mount options

**Implementation:**
```bash
# tracker.sh contract: called from launcher hooks
# $1 = model identifier (canonical string, e.g. "hf:meta-llama/Llama-3.2-8B")
touch "${MODELSTORE_USAGE_DIR}/${1//\//__}"
```

**Trade-offs:** Requires launcher hooks to call tracker. Benefit: reliable, filesystem-agnostic, auditable.

### Pattern 3: Relative Symlinks for Cross-Filesystem Portability

**What:** After moving a model directory to cold store, create a symlink at the original hot path pointing to the absolute cold store path.

**When to use:** For the hot→cold symlink (the "pointer" left in hot store). Use absolute paths here, not relative.

**Why absolute for the hot→cold link:**
- The symlink source is on internal NVMe; the target is on a different physical device at `/media/robert_li/modelstore-1tb/...`
- There is no meaningful relative path between the two mount points
- Relative symlinks only make sense within the same directory tree (as HF uses internally within a model dir)

**Atomic symlink replacement pattern:**
```bash
# Never ln -sf directly (brief window where symlink is absent)
ln -s "$COLD_TARGET" "${HOT_PATH}.new"
mv -T "${HOT_PATH}.new" "$HOT_PATH"
```
`mv -T` on Linux calls `rename(2)`, which is atomic — there is no window where the path is absent.

### Pattern 4: CLI Dispatcher with Pass-Through to Individual Scripts

**What:** `modelstore` is a thin dispatcher that sources config.sh, validates args, then `exec`s the appropriate cmd/ script. Cron and launcher hooks call cmd/ scripts directly, bypassing the dispatcher.

**When to use:** Always. The dispatcher is only for interactive UX; automation paths skip it.

**Dispatcher skeleton:**
```bash
#!/usr/bin/env bash
MODELSTORE_LIB="$(dirname "$(readlink -f "$0")")/../lib"
source "${MODELSTORE_LIB}/config.sh"

SUBCOMMAND="${1:-help}"
shift 2>/dev/null

case "$SUBCOMMAND" in
  init)     exec "${MODELSTORE_CMD}/init.sh" "$@" ;;
  status)   exec "${MODELSTORE_CMD}/status.sh" "$@" ;;
  migrate)  exec "${MODELSTORE_CMD}/migrate.sh" "$@" ;;
  recall)   exec "${MODELSTORE_CMD}/recall.sh" "$@" ;;
  revert)   exec "${MODELSTORE_CMD}/revert.sh" "$@" ;;
  *)        echo "Unknown subcommand: $SUBCOMMAND"; exit 1 ;;
esac
```

**Trade-offs:** `exec` replaces the shell process (no forking overhead); each cmd/ script is independently testable.

### Pattern 5: notify-send from Cron via Environment Injection

**What:** Cron jobs run without a desktop session environment. `notify-send` requires `DBUS_SESSION_BUS_ADDRESS`, `DISPLAY`, and `XDG_RUNTIME_DIR`. These must be read from the running user session before notifying.

**Implementation in notify.sh:**
```bash
notify_user() {
  local summary="$1" body="$2"
  local uid
  uid=$(id -u)
  # Locate session bus address from running dbus-daemon process
  local dbus_addr
  dbus_addr=$(grep -z DBUS_SESSION_BUS_ADDRESS \
    /proc/$(pgrep -u "$uid" gnome-session | head -1)/environ \
    2>/dev/null | tr -d '\0' | sed 's/DBUS_SESSION_BUS_ADDRESS=//')
  DISPLAY=":0" \
  XDG_RUNTIME_DIR="/run/user/${uid}" \
  DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
  notify-send --app-name="modelstore" "$summary" "$body"
}
```

**Trade-offs:** Brittle if user has no active GNOME session (silent failure is acceptable — disk warning is best-effort). Log the event regardless.

## Data Flow

### Migration Flow (cron trigger)

```
cron (2 AM)
    |
    v
migrate_cron.sh
    | sources config.sh (loads HOT_PATH, COLD_PATH, RETENTION_DAYS)
    | checks: cold drive mounted? (mountpoint -q COLD_PATH) → abort if not
    | checks: cold drive has space? (df --output=avail) → abort if insufficient
    v
hf_adapter.sh::list_stale_models(RETENTION_DAYS)
    | for each models--* dir in HOT_PATH:
    |   read ~/.modelstore/usage/{model-id} mtime
    |   if age > RETENTION_DAYS → yield model-id
    v
for each stale model:
    hf_adapter.sh::migrate(model-id)
        | rsync or mv model dir to COLD_PATH/huggingface/hub/
        | ln -s COLD_PATH/... HOT_PATH/models--{org}--{name}.new
        | mv -T ...new ...  (atomic swap)
    ollama_adapter.sh::migrate(model-id)  [if applicable]
        | parse manifest JSON for blob digests
        | mv manifest file to cold manifests tree
        | mv each referenced blob to cold blobs/
        | ln -s (atomic) for manifest and each blob path
    tracker.sh::reset_timestamp(model-id)  [NOT called — stale, so leave alone]
    |
    v
disk_check (also in migrate_cron.sh after migration):
    | check HOT and COLD drive usage (df)
    | if either >98%: notify.sh "modelstore: disk warning" "Drive X at N% capacity"
```

### Recall Flow (launcher trigger or manual)

```
Launcher script (vLLM, etc.)
    | hooks/tracker.sh "hf:{model-id}"   ← updates usage timestamp
    |
    v
does model path exist as real dir? YES → continue to launch
                                   NO (symlink) →
                                        recall.sh {model-id}
                                            | check cold drive mounted
                                            | mv cold dir → hot path (overwrite symlink)
                                            | mv -T atomic if symlink exists at dest
                                            | reset tracker timestamp
                                        → continue to launch
```

### Status Flow (interactive)

```
modelstore status
    |
    v
status.sh
    | sources config.sh
    | hf_adapter.sh::list_all()  → for each model: hot/cold tier, size, last-used timestamp
    | ollama_adapter.sh::list_all()
    | df -h HOT_PATH, COLD_PATH
    v
tabular output to stdout
```

### Init Flow (once, interactive)

```
modelstore init
    |
    v
init.sh
    | prompt: select hot drive (default: ~/.cache/huggingface/hub parent)
    | prompt: select cold drive (filesystem tree preview)
    | prompt: retention days (default: 14)
    | prompt: cron time (default: 2:00 AM)
    | create ~/.modelstore/{config,usage/}
    | create cold drive directory structure
    | install.sh: add crontab entries
    v
config written, cron installed, ready
```

## Scaling Considerations

This is a single-machine, two-tier local system. Traditional user-scaling doesn't apply. Relevant "scaling" dimensions are model count and drive size:

| Scale | Architecture Adjustments |
|-------|--------------------------|
| <50 models | Shell loops over directory listings are fine; no indexing needed |
| 50-200 models | Usage manifest scan is O(n) file stats; acceptable. Status command may be slow — add simple count/size cache in config |
| 200+ models | Shell loops become noticeable. If ever reached: replace usage manifest with a single SQLite file (one row per model). Not needed for initial implementation. |
| Multi-user | Out of scope — design is single-user (paths are user-home-relative) |

### Scaling Priorities

1. **First bottleneck:** `status.sh` iterates all model directories and reads timestamps — will be slow at 100+ models because each requires a `stat` call. Mitigation: cache last-scan results in `~/.modelstore/status_cache` with 5-minute TTL.
2. **Second bottleneck:** Ollama blob migration requires parsing JSON and correlating multiple files. With many overlapping models sharing blobs, reference counting becomes necessary before deletion. Mitigation: always migrate blobs by manifest reference — never delete a blob unless no manifest on either tier references it.

## Anti-Patterns

### Anti-Pattern 1: Tiering the Entire `~/.ollama/` Directory

**What people do:** Symlink the whole `~/.ollama` directory to the cold store (common advice in guides).

**Why it's wrong:** This moves ALL Ollama state including non-model data (config, logs). It also makes per-model tiering impossible — everything moves together. If the cold drive is unmounted, Ollama fails entirely rather than falling back to whatever is on hot.

**Do this instead:** Leave `~/.ollama/models/` on hot store. Mirror the internal sub-structure on cold store (`cold/ollama/models/manifests/` and `cold/ollama/models/blobs/`). Create individual symlinks per manifest file and per referenced blob.

### Anti-Pattern 2: Using `atime` for Last-Used Tracking

**What people do:** Check file access times with `stat` or `find -atime` to determine which models are stale.

**Why it's wrong:** `relatime` (the default ext4 mount option) only updates atime once per 24 hours. Symlinks report their own atime, not the blob's. The cold drive may be mounted with `noatime`. Result: migration triggers on recently-used models.

**Do this instead:** Maintain an explicit usage manifest in `~/.modelstore/usage/`. Launcher hooks write the timestamp explicitly and reliably.

### Anti-Pattern 3: Non-Atomic Symlink Replacement

**What people do:** `rm $LINK && ln -s $TARGET $LINK`

**Why it's wrong:** There is a window between `rm` and `ln` where the path does not exist. A concurrent model load during this window will fail with "file not found". On a DGX running multiple concurrent workloads, this is not theoretical.

**Do this instead:** `ln -s "$TARGET" "${LINK}.new" && mv -T "${LINK}.new" "$LINK"`. The `rename(2)` syscall behind `mv -T` is atomic.

### Anti-Pattern 4: CLI Dispatcher in the Cron Line

**What people do:** `0 2 * * * /usr/local/bin/modelstore migrate`

**Why it's wrong:** The CLI dispatcher sources interactive-UX code, may check for TTY, and adds an unnecessary process layer. Cron has no TTY; some interactive guards fail in unexpected ways.

**Do this instead:** `0 2 * * * /path/to/modelstore/cron/migrate_cron.sh`. Cron calls the thin cron wrapper directly.

### Anti-Pattern 5: Moving Blobs Without Checking Manifest References (Ollama)

**What people do:** Treat Ollama blobs like HF blobs — move the whole blob store for a model.

**Why it's wrong:** Ollama blobs are shared across models (same GGUF layer in llama3.1:8b and llama3.1:8b-q4). Moving a blob because one model is stale will break other models that reference the same blob.

**Do this instead:** Before migrating a blob, check all manifests (on both tiers) for references to that blob digest. Only migrate a blob when no hot-tier manifest references it.

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| HuggingFace cache | Direct filesystem manipulation — no HF Python APIs needed | All operations are `mv`, `ln`, `stat` on known directory structure |
| Ollama | Direct filesystem manipulation — no Ollama API needed | Parse manifest JSON with `jq` or `python3 -c json` (python3 is always available on DGX even without HF installed) |
| GNOME notifications | `notify-send` with injected DBus session env vars | Silent failure acceptable; always log to file as backup |
| cron | Crontab entries installed by `install.sh` using `crontab -l | ... | crontab -` pattern | No root required; user crontab only |
| NVIDIA Sync | Individual cmd/ scripts work without TTY; no interactive prompts in non-init paths | Sync invokes scripts remotely; `init.sh` is the only interactive command |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| `modelstore` CLI → cmd/ scripts | `exec` with argv passthrough | Dispatcher exits; cmd/ script takes over process |
| cmd/ scripts → lib/ | `source` (bash dot-operator) | lib/ scripts must be side-effect-free on source |
| Launcher scripts → `tracker.sh` | Direct call: `tracker.sh "hf:{model-id}"` | One-liner addition to each launcher; must not block launch on failure |
| `migrate.sh` → adapters | Sourced functions: `hf_list_stale`, `hf_migrate`, `ollama_list_stale`, `ollama_migrate` | Adapter functions receive model-id and config vars |
| cron wrapper → core scripts | Direct call with absolute paths | Cron has minimal PATH; use full paths throughout |

## Suggested Build Order

Dependencies flow from bottom to top. Build in this order:

1. **Config layer** (`lib/config.sh`, `~/.modelstore/` state dir structure)
   Required by everything else. Define config schema before writing any logic.

2. **Common helpers** (`lib/common.sh`)
   Mount check, space check, logging — used by both adapters and all cmd/ scripts.

3. **HF adapter** (`lib/hf_adapter.sh`)
   Simpler of the two formats. Validates the overall adapter pattern before tackling Ollama.

4. **Ollama adapter** (`lib/ollama_adapter.sh`)
   More complex (blob reference counting). Build after HF adapter pattern is proven.

5. **Tracker** (`hooks/tracker.sh`)
   Tiny; needed before testing migration logic.

6. **Migration script** (`cmd/migrate.sh`)
   Core value. Depends on both adapters, common helpers, config.

7. **Recall script** (`cmd/recall.sh`)
   Inverse of migration. Depends on adapters.

8. **Status script** (`cmd/status.sh`)
   Depends on adapters and tracker state. Useful for validating migration/recall.

9. **Notify helper** (`lib/notify.sh`)
   Needed for cron disk warnings. Low complexity; can be built alongside migrate.

10. **Cron wrappers** (`cron/migrate_cron.sh`, `cron/disk_check_cron.sh`)
    Thin wrappers; build after core scripts are tested.

11. **CLI dispatcher** (`bin/modelstore`)
    Build last. It's just a router; all logic is already in cmd/. Add `init.sh` and `revert.sh` here too.

12. **Launcher hooks**
    Add one-liners to existing DGX Toolbox launcher scripts after tracker.sh is proven.

## Sources

- [HuggingFace Hub Cache Documentation](https://huggingface.co/docs/huggingface_hub/en/guides/manage-cache) — official; HIGH confidence
- [Ollama Model Storage Internals (DeepWiki)](https://deepwiki.com/ollama/ollama/4-model-management) — derived from source; HIGH confidence
- [Ollama Blob/Manifest article (Medium, Feb 2026)](https://medium.com/@enisbaskapan/how-ollama-stores-models-11fc47f48955) — MEDIUM confidence
- [Atomic symlink replacement via mv -T](https://rcrowley.org/2010/01/06/things-unix-can-do-atomically.html) — well-established POSIX pattern; HIGH confidence
- [notify-send from cron: env injection approach](https://selivan.github.io/2016/07/08/notify-send-from-cron-in-ubuntu.html) — MEDIUM confidence; verified against multiple community sources
- [Linux filesystem timestamps (atime/relatime)](https://www.howtogeek.com/517098/linux-file-timestamps-explained-atime-mtime-and-ctime/) — HIGH confidence
- [Symlinks across filesystems](https://opensource.com/article/17/6/linking-linux-filesystem) — HIGH confidence
- [Bash subcommand dispatcher pattern](https://gist.github.com/waylan/4080362) — MEDIUM confidence; common idiom

---
*Architecture research for: tiered ML model storage (HuggingFace + Ollama, DGX Spark)*
*Researched: 2026-03-21*
