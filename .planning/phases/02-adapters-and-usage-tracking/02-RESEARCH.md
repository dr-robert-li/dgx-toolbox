# Phase 2: Adapters and Usage Tracking - Research

**Researched:** 2026-03-21
**Domain:** Bash adapter pattern, background daemon (docker events + inotifywait), JSON manifest tracking, Ollama API integration, HF cache filesystem layout
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Usage timestamp format:**
- Single JSON manifest at `~/.modelstore/usage.json`
- Model IDs are path-based (the actual directory/blob path as ID — most precise)
- Timestamps updated on both launcher start (container/process launch) AND specific model load when parseable from args/config
- Format: `{"<path>": "<ISO-8601 timestamp>"}`

**Launcher hook integration — Background daemon:**
- NO modifications to existing launcher scripts — zero-touch approach
- Background watcher daemon monitors both Docker events (for containerized tools) and filesystem access via `inotifywait` (for direct access like `ollama run`)
- Docker events: watch `docker events --filter event=start`, parse image/args to identify which model
- Filesystem: `inotifywait -m -e access` on HF cache and Ollama models dirs
- Daemon lifecycle: cron ensures it's running (pidfile check). Not a systemd service.
- Must be agnostic — works for any script that touches model files, not just the four named launchers
- Failure mode: warn to stderr and continue — tracker failure never blocks model access

**Ollama server interaction:**
- Detection: `systemctl is-active ollama` first, then `/api/tags` for loaded models
- Warning level: BLOCK — refuse to operate on Ollama models while server is active. User must stop Ollama first.
- Permissions: API-only for all operations — NO sudo, NO direct file access
  - Enumeration: `/api/tags` for model list with sizes
  - Migration (Phase 3): `ollama cp` to copy model to cold-mounted path, `ollama rm` to remove from hot
  - This avoids all permission issues with the system `ollama` user's files

**HF vs Ollama adapter scope — Full adapters:**
- Both adapters expose full operation set in Phase 2 (not just enumerate):
  - `list_models()` — enumerate all models with sizes
  - `get_model_size(model_id)` — size of a single model
  - `get_model_path(model_id)` — full path to model
  - `migrate_model(model_id, cold_path)` — move to cold + create symlink
  - `recall_model(model_id, hot_path)` — move back from cold, replace symlink
- HF migration unit: whole `models--org--name/` directory (preserves internal relative symlinks — confirmed by research)
- Ollama migration: API-driven (`ollama cp` to cold path, `ollama rm` from hot). No filesystem operations.

**Daemon design:**
- Single script `hooks/watcher.sh` — two background processes (docker events + inotifywait) within one script, same pidfile
- Cron-based lifecycle: cron pidfile check restarts daemon if dead

### Claude's Discretion

- inotifywait event mask (which events beyond `access` to watch)
- Docker event parsing logic (how to extract model name from container args)
- JSON manifest locking strategy (flock on usage.json)
- Adapter function signatures and error handling patterns

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| TRCK-01 | Usage tracker maintains a timestamp manifest file per model, updated on every load | JSON manifest at `~/.modelstore/usage.json`, updated by `hooks/watcher.sh` on inotify `access` events and docker container starts. Uses `jq` for atomic writes with `flock`. |
| TRCK-02 | Existing DGX Toolbox launcher scripts are hooked to call the usage tracker | Implemented via zero-touch background daemon (not launcher modifications). `hooks/watcher.sh` watches docker events and inotifywait on HF/Ollama dirs, updates usage.json without modifying any launcher. |
| SAFE-01 | Migration refuses to create symlinks if cold drive is not mounted (verified via `mountpoint -q`) | `check_cold_mounted()` already implemented in `lib/common.sh`. Adapter `migrate_model()` calls it as first guard. |
| SAFE-02 | Migration checks available space on destination drive with 10% safety margin before moving | `check_space()` already implemented in `lib/common.sh`. Adapter `migrate_model()` calls it with `du -sb` source size estimate. |
| SAFE-06 | Ollama server state is checked before migrating Ollama models (warn if running) | `ollama_check_server()` function in `lib/ollama_adapter.sh`. Uses `systemctl is-active ollama` first, falls back to curl `/api/tags`. Decision: BLOCK (not warn) while server active. |
</phase_requirements>

---

## Summary

Phase 2 builds the storage adapter layer and background usage tracking daemon that Phase 3 (migration cron) will consume. The work divides cleanly into three areas: (1) `lib/hf_adapter.sh` exposing the five-function operation set against HF's `models--*/` directory structure, (2) `lib/ollama_adapter.sh` exposing the same interface via Ollama's HTTP API only (no filesystem access), and (3) `hooks/watcher.sh`, a background daemon that updates `~/.modelstore/usage.json` by watching docker events and inotifywait filesystem events in parallel.

All safety primitives (`check_cold_mounted`, `check_space`, `validate_cold_fs`, `ms_log`, `ms_die`) are already implemented in `lib/common.sh` from Phase 1 and must be reused verbatim. The config primitives (`load_config`, `config_read`, `write_config`) in `lib/config.sh` are also complete and provide the `HOT_HF_PATH`, `HOT_OLLAMA_PATH`, and `COLD_PATH` vars that adapters will consume. The model enumeration patterns in `cmd/init.sh` (`scan_hf_models` via Python API + fallback, `scan_ollama_models` via `/api/tags` + fallback) are the source of truth for list_models logic — adapters extract those patterns into reusable functions.

The most design-sensitive area is the watcher daemon: it must combine two parallel background processes (docker events + inotifywait) under one pidfile, write to a shared JSON file safely under flock, and never block model access on failure. The Ollama adapter carries a unique constraint: all operations are API-only and must BLOCK (not just warn) when the Ollama server is active for any mutation operation.

**Primary recommendation:** Build adapters first (HF then Ollama), then tracker daemon. All safety functions are ready — call them, don't rewrite them.

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| bash 5.2.21 | system | Script runtime for all adapters and daemon | Project constraint — host scripts must be bash-only |
| jq | system | JSON read/write for usage.json and Ollama API responses | Already used in `config.sh` for all JSON ops; consistent pattern |
| flock | util-linux (system) | Exclusive lock on usage.json during writes | Prevents concurrent watcher processes from corrupting JSON |
| inotify-tools / inotifywait | 3.22.6.0 (apt) | Filesystem event monitoring for model file accesses | Kernel-level, zero-CPU idle; already in stack research |
| curl | system | Ollama API calls (`/api/tags`, `/api/show`) | Already used in `init.sh` for Ollama enumeration |
| docker CLI | system | `docker events --filter event=start` for container tracking | Zero new dependencies; DGX always has docker |
| rsync 3.2.7 | system | File migration for `migrate_model()` in HF adapter | `--remove-source-files` for atomic cross-filesystem move |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| python3 | system | HF Python API (`scan_cache_dir`, `constants.HF_HUB_CACHE`) | Primary HF enumeration path; same pattern as `init.sh` |
| numfmt | coreutils (system) | Human-readable size formatting | Status/list output formatting — same as `init.sh` |
| stat | coreutils (system) | Get file modification times | Usage.json entry reading in adapters |
| date | coreutils (system) | ISO-8601 timestamp generation | `date -u +%Y-%m-%dT%H:%M:%SZ` for usage.json values |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| JSON usage.json via jq | Per-model timestamp files (`touch ~/.modelstore/usage/<id>`) | User decided JSON manifest. jq is already the config pattern. Per-file approach was simpler but produces a directory of tiny files. |
| inotifywait daemon | Polling loop | inotifywait is zero-CPU idle; polling wastes resources. inotifywait is the right tool. |
| flock on usage.json | Temp file + mv atomic writes | flock is simpler and already in the stack. jq does not have atomic-write mode so flock is required. |
| systemd service for daemon | Cron + pidfile | User decided cron. No systemd unit file to maintain. |

**Installation:**

```bash
# All tools already on host — verify inotify-tools present
sudo apt install inotify-tools  # if not already installed
```

---

## Architecture Patterns

### Recommended Project Structure (Phase 2 additions)

```
modelstore/
├── lib/
│   ├── common.sh          # EXISTING — do not modify
│   ├── config.sh          # EXISTING — do not modify
│   ├── hf_adapter.sh      # NEW — HF cache adapter (5 functions)
│   └── ollama_adapter.sh  # NEW — Ollama API adapter (5 functions + server check)
├── hooks/
│   └── watcher.sh         # NEW — background daemon (docker events + inotifywait)
└── test/
    ├── test-hf-adapter.sh      # NEW — unit tests for hf_adapter.sh
    ├── test-ollama-adapter.sh  # NEW — unit tests for ollama_adapter.sh
    └── test-watcher.sh         # NEW — unit tests for watcher.sh lifecycle
```

Note: `usage.json` is a runtime artifact at `~/.modelstore/usage.json` — already created by `init.sh` (which calls `mkdir -p ~/.modelstore/usage` in Phase 1, but the file itself does not yet exist).

### Pattern 1: Adapter Function Signature Convention

**What:** All adapter functions follow a consistent signature and error return contract. They are pure functions: they source common.sh and config.sh (already sourced by callers), use the env vars those set, and return 0 on success or non-zero on failure with an `ms_log` message.

**When to use:** Always. Consistent signatures let migrate.sh and recall.sh call HF and Ollama adapters interchangeably.

**Recommended signatures:**

```bash
# Source: established by Phase 1 common.sh/config.sh patterns

# hf_list_models — prints TSV: model_id\tsize_bytes\tpath
hf_list_models() { ... }

# hf_get_model_size model_id — prints bytes to stdout
hf_get_model_size() { local model_id="$1"; ... }

# hf_get_model_path model_id — prints absolute path to stdout
hf_get_model_path() { local model_id="$1"; ... }

# hf_migrate_model model_id cold_base_path — moves dir + creates symlink
# Calls check_cold_mounted, check_space, then rsync + atomic symlink
hf_migrate_model() { local model_id="$1" cold_base="$2"; ... }

# hf_recall_model model_id hot_base_path — moves cold dir back, removes symlink
hf_recall_model() { local model_id="$1" hot_base="$2"; ... }
```

**Ollama adapter mirrors this interface but is API-driven:**

```bash
# ollama_check_server — returns 0 if server is running, 1 if not
# Used as guard before all mutation operations
ollama_check_server() { ... }

# ollama_list_models — prints TSV: model_name\tsize_bytes\tdigest
ollama_list_models() { ... }

# ollama_get_model_size model_name — prints bytes to stdout
ollama_get_model_size() { local model_name="$1"; ... }

# ollama_get_model_path model_name — prints manifest path (API-reported)
ollama_get_model_path() { local model_name="$1"; ... }

# ollama_migrate_model model_name cold_base_path — ollama cp + ollama rm
# BLOCKS if server is active (calls ollama_check_server as first guard)
ollama_migrate_model() { local model_name="$1" cold_base="$2"; ... }

# ollama_recall_model model_name hot_base_path — ollama cp back + remove cold
ollama_recall_model() { local model_name="$1" hot_base="$2"; ... }
```

### Pattern 2: HF Adapter — Python API Primary, Directory Walk Fallback

**What:** Reuse the exact pattern from `init.sh:scan_hf_models()`. Python `huggingface_hub.scan_cache_dir()` is the authoritative source for model IDs and sizes. Directory walk is the fallback.

**Model ID convention for HF:** The path-based ID is the `models--org--name` directory name. The human-readable form is `org/name` (double-dash separator). The usage.json key should be the full absolute path to the `models--*/` dir (as decided: path-based IDs).

```bash
# Pattern extracted from init.sh:scan_hf_models()
# Source: modelstore/cmd/init.sh lines 96-127 (Phase 1 implementation)

hf_list_models() {
  load_config  # sets HOT_HF_PATH

  # Primary: Python API
  if python3 -c "from huggingface_hub import scan_cache_dir" &>/dev/null; then
    python3 -c "
from huggingface_hub import scan_cache_dir
import os
info = scan_cache_dir()
for repo in info.repos:
    # path-based ID: absolute path to models-- directory
    path = str(repo.repo_path)
    print(f'{path}\t{repo.size_on_disk}')
" 2>/dev/null
    return 0
  fi

  # Fallback: directory walk
  for model_dir in "${HOT_HF_PATH}"/models--*/; do
    [[ -d "$model_dir" ]] || continue
    size=$(du -sb "$model_dir" 2>/dev/null | cut -f1)
    echo "${model_dir%/}\t${size}"
  done
}
```

**Migration unit is always the whole `models--org--name/` dir.** Never operate on `blobs/` or `snapshots/` subdirs independently.

### Pattern 3: Ollama Adapter — API-Only Operations

**What:** All read operations use `/api/tags` and `/api/show`. All mutation operations are blocked when server is active. Migration Phase 3 will use `ollama cp` + `ollama rm` via the CLI.

**Key Ollama API fields** (from `init.sh:scan_ollama_models()` confirmed pattern):

```bash
# GET /api/tags response structure (verified in init.sh):
# .models[].name         — model tag (e.g. "llama3.2:latest")
# .models[].size         — total size in bytes
# .models[].modified_at  — ISO-8601 timestamp

# /api/show request for per-model detail:
# POST {"name": "llama3.2:latest"}
# Response includes: .modelfile, .parameters, .details
# Note: /api/show does NOT expose the blob file path — no filesystem access needed

ollama_check_server() {
  # systemctl first (authoritative), then curl as fallback
  if systemctl is-active --quiet ollama 2>/dev/null; then
    return 0
  fi
  if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

ollama_migrate_model() {
  local model_name="$1" cold_base="$2"
  # BLOCK if server active — user must stop Ollama first
  if ollama_check_server; then
    ms_die "Ollama server is active. Stop it first: systemctl stop ollama"
  fi
  check_cold_mounted "$cold_base"
  # Phase 3 will implement: ollama cp + ollama rm
  # Phase 2 provides the function stub with correct guard structure
}
```

**Ollama model path gotcha (from STATE.md blocker):** The manifest JSON schema field paths are not fully verified without running `cat ~/.ollama/models/manifests/...` on actual DGX. The `/api/show` endpoint does not expose raw blob paths. Phase 2 avoids direct filesystem operations for Ollama entirely (API-only decision), so this is not blocking. The fallback path in `init.sh` (direct manifest scan, lines 186-217) shows the filesystem structure if needed for reference.

### Pattern 4: Background Daemon (hooks/watcher.sh)

**What:** Single script combining docker events monitor and inotifywait monitor as two parallel background processes, both managed under one pidfile.

**Lifecycle:**
```bash
# Daemon entry point pattern
PIDFILE="${HOME}/.modelstore/watcher.pid"

# Check if already running
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  exit 0  # already running
fi

# Write our own PID
echo "$$" > "$PIDFILE"

# Cleanup on exit
cleanup() { rm -f "$PIDFILE"; kill "${DOCKER_PID:-}" "${INOTIFY_PID:-}" 2>/dev/null; }
trap cleanup EXIT INT TERM

# Start docker events watcher in background
watch_docker_events &
DOCKER_PID=$!

# Start inotifywait watcher in background
watch_inotify &
INOTIFY_PID=$!

# Wait for either to exit (signals overall failure)
wait -n 2>/dev/null || wait
```

**Cron entry for daemon keepalive (to be added in Phase 2 install):**

```cron
*/5 * * * * [[ -f ~/.modelstore/watcher.pid ]] && kill -0 "$(cat ~/.modelstore/watcher.pid)" 2>/dev/null || /path/to/modelstore/hooks/watcher.sh &
```

**Docker event parsing:**

```bash
watch_docker_events() {
  docker events --filter "event=start" --format '{{json .}}' 2>/dev/null \
  | while IFS= read -r event_json; do
      # Extract image name and container args
      image=$(echo "$event_json" | jq -r '.Actor.Attributes.image // empty')
      # Parse HF model path from container env/mounts if present
      # Pattern: look for HF_HUB_CACHE mount or --model-name arg
      # This is discretionary — best-effort extraction
      local model_path
      model_path=$(extract_model_from_docker_event "$event_json") || continue
      [[ -n "$model_path" ]] && ms_track_usage "$model_path"
    done
}
```

**inotifywait event mask (Claude's discretion recommendation):**
- Use `access,open` — `access` catches read (model weights loaded), `open` catches file open before read
- Exclude `close_nowrite` — too noisy (every stat call)
- Use `-r` (recursive) on model dirs with `--exclude '\.lock$'` to skip HF download locks

```bash
watch_inotify() {
  load_config
  local watch_paths=()
  [[ -d "$HOT_HF_PATH" ]]    && watch_paths+=("$HOT_HF_PATH")
  [[ -d "$HOT_OLLAMA_PATH" ]] && watch_paths+=("$HOT_OLLAMA_PATH")
  [[ ${#watch_paths[@]} -eq 0 ]] && return 0

  inotifywait -m -r -e access,open \
    --exclude '\.lock$' \
    --format '%w%f' \
    "${watch_paths[@]}" 2>/dev/null \
  | while IFS= read -r accessed_path; do
      local model_path
      model_path=$(extract_model_id_from_path "$accessed_path") || continue
      [[ -n "$model_path" ]] && ms_track_usage "$model_path"
    done
}
```

### Pattern 5: JSON Manifest Write with flock

**What:** usage.json is a shared resource written by the watcher daemon. flock prevents concurrent writes from corrupting the JSON.

**Locking strategy (Claude's discretion recommendation):**

```bash
USAGE_FILE="${HOME}/.modelstore/usage.json"
USAGE_LOCK="${HOME}/.modelstore/usage.lock"

ms_track_usage() {
  local model_path="$1"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Initialize if missing
  [[ -f "$USAGE_FILE" ]] || echo '{}' > "$USAGE_FILE"

  # Acquire exclusive lock, update JSON atomically
  (
    flock -x 9
    local current
    current=$(cat "$USAGE_FILE")
    echo "$current" | jq --arg path "$model_path" --arg ts "$timestamp" \
      '.[$path] = $ts' > "${USAGE_FILE}.tmp" \
    && mv "${USAGE_FILE}.tmp" "$USAGE_FILE"
  ) 9>"$USAGE_LOCK" 2>/dev/null || ms_log "WARNING: failed to update usage for $model_path"
}
```

Key details:
- Use a separate `.lock` file (not the JSON itself) as the flock target — avoids locking a file that's also being read/written
- Write to `.tmp` then `mv` for atomicity — if jq fails, usage.json is not corrupted
- Failure mode: log warning, do NOT exit — tracker failure must never block model access

### Anti-Patterns to Avoid

- **Calling `sudo` in Ollama adapter:** Never. The user decision is API-only. Any function that needs sudo is wrong.
- **Modifying launcher scripts:** Zero-touch approach — watcher.sh monitors events, does not hook launchers.
- **Using `atime` for usage tracking:** Unreliable with `relatime` mount defaults. JSON manifest is the source of truth.
- **Blocking model access on tracker failure:** Tracker uses `|| true` / warn-and-continue pattern everywhere.
- **inotifywait on the entire home directory:** Watch only `HOT_HF_PATH` and `HOT_OLLAMA_PATH` — recursive watch of home generates massive noise.
- **Single flock on usage.json file descriptor:** Use a separate `.lock` file so readers are never blocked.
- **Hardcoded paths in adapters:** Always use `HOT_HF_PATH`, `HOT_OLLAMA_PATH`, `COLD_PATH` from `load_config`.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Atomic JSON update | Custom temp-file pattern | jq + mv + flock | jq handles malformed input gracefully; the pattern is one command |
| Cross-filesystem file move | cp + rm | rsync `--remove-source-files` | rsync only removes source after successful transfer; cp+rm leaves orphaned data on interruption |
| Atomic symlink replacement | rm + ln -s | `ln -s target link.new && mv -T link.new link` | mv -T calls rename(2), which is atomic; rm+ln has a gap window |
| Mount check | `test -d` or `ls` | `mountpoint -q` | test -d returns true for an empty mount point directory even when drive is unmounted |
| Ollama model listing | Parse manifest files | curl `/api/tags` | Filesystem access to Ollama models dir has permission issues; API is the locked decision |
| HF model size calculation | Custom du loop | `huggingface_hub.scan_cache_dir()` or `du -sb` | Python API is exact; du -sb with 10% margin matches Phase 1 check_space pattern |
| Background process keepalive | Restart loop inside script | Cron + pidfile | Simpler, no sleep loops, survives host reboot |

**Key insight:** Everything needed already exists — common.sh and config.sh have the safety functions, init.sh has the enumeration patterns. Phase 2 extracts patterns into reusable library functions; it adds almost no new algorithms.

---

## Common Pitfalls

### Pitfall 1: inotifywait Event Storm on Large HF Caches

**What goes wrong:** HF cache contains hundreds of symlinks in `snapshots/`. Loading a model triggers `access` events on every symlink traversal and every blob file read — potentially thousands of events per second during model load.

**Why it happens:** inotifywait `-e access` is very low-level. A 7B model in safetensors format with 8 shards triggers 8+ access events immediately.

**How to avoid:** Debounce in the `while read` loop. Track the last-updated timestamp per model and skip updates within a 60-second window:

```bash
# Debounce: skip if this model was tracked in the last 60 seconds
if [[ -f "$USAGE_FILE" ]]; then
  last_ts=$(jq -r --arg p "$model_path" '.[$p] // empty' "$USAGE_FILE" 2>/dev/null)
  if [[ -n "$last_ts" ]]; then
    last_epoch=$(date -d "$last_ts" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    [[ $(( now_epoch - last_epoch )) -lt 60 ]] && continue
  fi
fi
```

**Warning signs:** usage.json being written hundreds of times per minute; watcher.sh CPU usage visible in top during model load.

### Pitfall 2: Docker Event Model Extraction Ambiguity

**What goes wrong:** `docker events --filter event=start` gives container start events, but the model path is buried in container args that vary by launcher script (vLLM uses `--model`, eval-toolbox may use env vars, etc.). Best-effort parsing will sometimes miss the model or extract the wrong path.

**Why it happens:** There is no standard Docker label or env var convention for "this container uses model X". Launcher scripts pass the model path differently.

**How to avoid:** Treat docker event model extraction as best-effort, not authoritative. If docker event parsing fails to extract a model path, log at DEBUG level and continue — inotifywait will catch the actual file access anyway. The two watchers are complementary, not redundant.

**Warning signs:** Models being used but not showing up in usage.json — check inotifywait path resolution.

### Pitfall 3: usage.json Written Before Directory Exists

**What goes wrong:** watcher.sh starts before init has been run. `~/.modelstore/` may not exist. Attempting to write usage.json or lock file fails silently or with permission errors.

**Why it happens:** Cron installs the watcher keepalive at init time, but if cron entry persists after a clean install without running init again, the daemon starts against a missing state dir.

**How to avoid:** watcher.sh must check for `~/.modelstore/config.json` existence at startup and exit silently (not with error) if modelstore is not initialized:

```bash
if [[ ! -f "${HOME}/.modelstore/config.json" ]]; then
  exit 0  # Not yet initialized — nothing to watch
fi
```

### Pitfall 4: Ollama Server Check Race in ollama_migrate_model

**What goes wrong:** `ollama_check_server` returns false (server not running), migration begins, user starts Ollama server while migration is in progress. Ollama reads a manifest that is mid-move.

**Why it happens:** Check-then-act is inherently racy without a lock.

**How to avoid:** For Phase 2, the check is sufficient because `ollama_migrate_model` is a stub — actual migration is Phase 3. When Phase 3 implements it, use `flock` around the entire migrate sequence. Document this as a known limitation of the Phase 2 stub.

### Pitfall 5: Symlink Targets in inotifywait Output

**What goes wrong:** HF `snapshots/` contains symlinks pointing to `../../blobs/sha256-...`. When a symlink is followed, inotifywait reports the *resolved blob path* (not the snapshot symlink path). The model ID extraction must map blob paths back to their `models--*/` parent directory.

**Why it happens:** inotifywait reports the actual file descriptor that was opened — the kernel resolves symlinks transparently.

**How to avoid:**

```bash
# Extract model ID from any path within an HF model directory
extract_model_id_from_hf_path() {
  local path="$1"
  # Find the models-- ancestor directory
  local dir="$path"
  while [[ "$dir" != "/" && "$dir" != "$HOT_HF_PATH" ]]; do
    if [[ "$(basename "$dir")" == models--* ]]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}
```

---

## Code Examples

Verified patterns from Phase 1 implementation and official sources:

### HF Model Enumeration (source: cmd/init.sh lines 96-127)

```bash
# Pattern reused in hf_list_models():
# Primary via Python API
python3 -c "
from huggingface_hub import scan_cache_dir
info = scan_cache_dir()
for repo in info.repos:
    print(f'{repo.repo_path}\t{repo.size_on_disk}')
" 2>/dev/null

# Fallback: directory walk
for model_dir in "${HOT_HF_PATH}"/models--*/; do
  [[ -d "$model_dir" ]] || continue
  size=$(du -sb "$model_dir" 2>/dev/null | cut -f1)
  printf '%s\t%s\n' "${model_dir%/}" "$size"
done
```

### Ollama Model Enumeration (source: cmd/init.sh lines 158-184)

```bash
# Primary via /api/tags
curl -sf http://localhost:11434/api/tags 2>/dev/null \
  | jq -r '.models[] | [.name, (.size|tostring)] | @tsv'
```

### Mount Check (source: lib/common.sh)

```bash
# Already implemented — call, don't rewrite
check_cold_mounted "$COLD_PATH"  # exits via ms_die if not mounted
```

### Space Check (source: lib/common.sh)

```bash
# Already implemented — call, don't rewrite
model_size=$(du -sb "$model_path" | cut -f1)
check_space "$COLD_PATH" "$model_size"  # returns 1 if insufficient
```

### Atomic Symlink Replacement (source: ARCHITECTURE.md Pattern 3)

```bash
# Source: .planning/research/ARCHITECTURE.md
ln -s "$cold_target" "${hot_path}.new"
mv -T "${hot_path}.new" "$hot_path"
```

### ISO-8601 Timestamp for usage.json

```bash
date -u +%Y-%m-%dT%H:%M:%SZ
```

### flock + jq JSON Update Pattern

```bash
# Source: recommended pattern for usage.json writes
(
  flock -x 9
  jq --arg k "$model_path" --arg v "$timestamp" \
    '.[$k] = $v' "$USAGE_FILE" > "${USAGE_FILE}.tmp" \
  && mv "${USAGE_FILE}.tmp" "$USAGE_FILE"
) 9>"${HOME}/.modelstore/usage.lock"
```

### Ollama Server Check

```bash
# systemctl first, curl fallback
ollama_check_server() {
  systemctl is-active --quiet ollama 2>/dev/null && return 0
  curl -sf http://localhost:11434/api/tags >/dev/null 2>&1 && return 0
  return 1
}
```

### watcher.sh Startup Guard

```bash
# Exit silently if modelstore not initialized
[[ -f "${HOME}/.modelstore/config.json" ]] || exit 0

# Single-instance via pidfile
PIDFILE="${HOME}/.modelstore/watcher.pid"
[[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && exit 0
echo "$$" > "$PIDFILE"
trap 'rm -f "$PIDFILE"; kill "${DOCKER_PID:-}" "${INOTIFY_PID:-}" 2>/dev/null' EXIT INT TERM
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Launcher hook one-liners in each launcher script | Zero-touch background daemon | Decided in CONTEXT.md Phase 2 discussion | No modification of existing scripts; works for any new launcher automatically |
| Per-model timestamp files (`touch ~/.modelstore/usage/<id>`) | Single JSON manifest (`usage.json`) | Decided in CONTEXT.md | Simpler to read from Phase 3 cron; single file to lock |
| Architecture doc suggested `tracker.sh` called from launchers | `hooks/watcher.sh` daemon | CONTEXT.md overrides ARCHITECTURE.md | The architecture doc is superseded for Phase 2 by CONTEXT.md decisions |

**Note:** The architecture research doc (ARCHITECTURE.md) describes `tracker.sh` as called from launcher scripts. CONTEXT.md overrides this design — the daemon approach replaces per-launcher hooks entirely. The file goes in `hooks/watcher.sh` not `hooks/tracker.sh`.

---

## Open Questions

1. **Ollama manifest JSON field paths**
   - What we know: `/api/tags` gives name + size (confirmed in init.sh). `/api/show` exists but field paths for blob locations are not verified.
   - What's unclear: For Phase 3 (`ollama cp` to cold path), what path argument does `ollama cp` accept? Does it support arbitrary destination paths or only local model names?
   - Recommendation: Phase 2 Ollama adapter `migrate_model` is a stub that validates guards (server check, mount check, space check) but defers the actual `ollama cp` implementation to Phase 3. The STATE.md blocker notes: "verify with `cat ~/.ollama/models/manifests/...` on actual DGX before writing ollama_adapter.sh". This is acceptable — Phase 2 provides the full function interface with correct guard structure.

2. **Docker event model path extraction — per-launcher format**
   - What we know: `docker events --format '{{json .}}'` gives Actor.Attributes including image name and container labels.
   - What's unclear: Whether DGX Toolbox launcher scripts set any consistent Docker label or env var for the model path. If not, extraction must parse container command args from the event JSON.
   - Recommendation: Implement best-effort extraction with `jq` parsing of known patterns (vLLM `--model` arg, etc.). Document that docker event tracking is supplemental to inotifywait (which is authoritative).

3. **inotifywait on symlinks vs real files**
   - What we know: HF snapshots use relative symlinks pointing to blobs. inotifywait reports the blob path (resolved target).
   - What's unclear: Whether inotifywait `-r` follows symlinks into HF model directories when those directories are themselves symlinks (migrated to cold store). If a model is on cold store with a symlink at the hot path, inotifywait watching the hot path directory may not follow the symlink to the cold-tier files.
   - Recommendation: For Phase 2, watch only the hot-tier directories. Models on cold store that are accessed via symlink will trigger inotify events at the cold-store path — but the cold store may not be watched. This is acceptable for Phase 2 scope since migration is Phase 3; all models are on hot during Phase 2.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Inline bash assertions (custom, no bats dependency) |
| Config file | None — test files are self-contained scripts |
| Quick run command | `bash modelstore/test/test-hf-adapter.sh` |
| Full suite command | `bash modelstore/test/run-all.sh` |

Pattern (from existing tests): Each test file defines `assert_eq`, `assert_ok`, `report` inline and calls `report` at end. Exit code 0 = all pass.

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| TRCK-01 | `ms_track_usage` writes ISO-8601 timestamp to usage.json for given path | unit | `bash modelstore/test/test-watcher.sh` | Wave 0 |
| TRCK-01 | `ms_track_usage` updates existing entry, not appends | unit | `bash modelstore/test/test-watcher.sh` | Wave 0 |
| TRCK-01 | Concurrent `ms_track_usage` calls do not corrupt usage.json | unit | `bash modelstore/test/test-watcher.sh` | Wave 0 |
| TRCK-02 | Daemon starts and writes pidfile | unit | `bash modelstore/test/test-watcher.sh` | Wave 0 |
| TRCK-02 | Daemon exits cleanly if not initialized (no config.json) | unit | `bash modelstore/test/test-watcher.sh` | Wave 0 |
| TRCK-02 | Daemon does not start second instance (pidfile guard) | unit | `bash modelstore/test/test-watcher.sh` | Wave 0 |
| SAFE-01 | `hf_migrate_model` calls `check_cold_mounted` — aborts if cold not mounted | unit | `bash modelstore/test/test-hf-adapter.sh` | Wave 0 |
| SAFE-01 | `ollama_migrate_model` calls `check_cold_mounted` — aborts if cold not mounted | unit | `bash modelstore/test/test-ollama-adapter.sh` | Wave 0 |
| SAFE-02 | `hf_migrate_model` calls `check_space` with model size — aborts if insufficient | unit | `bash modelstore/test/test-hf-adapter.sh` | Wave 0 |
| SAFE-06 | `ollama_migrate_model` calls `ollama_check_server` — blocks when server active | unit | `bash modelstore/test/test-ollama-adapter.sh` | Wave 0 |
| SAFE-06 | `ollama_check_server` returns 0 when `systemctl is-active ollama` succeeds | unit | `bash modelstore/test/test-ollama-adapter.sh` | Wave 0 |
| SAFE-06 | `ollama_check_server` returns 0 when curl `/api/tags` succeeds | unit | `bash modelstore/test/test-ollama-adapter.sh` | Wave 0 |

### Sampling Rate

- **Per task commit:** `bash modelstore/test/run-all.sh`
- **Per wave merge:** `bash modelstore/test/run-all.sh`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps

- [ ] `modelstore/test/test-hf-adapter.sh` — covers SAFE-01, SAFE-02 for HF adapter; `hf_list_models`, `hf_get_model_path`, `hf_migrate_model` guard behavior
- [ ] `modelstore/test/test-ollama-adapter.sh` — covers SAFE-01, SAFE-06; `ollama_check_server`, `ollama_list_models`, `ollama_migrate_model` guard behavior
- [ ] `modelstore/test/test-watcher.sh` — covers TRCK-01, TRCK-02; `ms_track_usage` JSON writes, flock correctness, pidfile lifecycle
- [ ] `modelstore/test/run-all.sh` — update to include the three new test files (existing file, needs modification)

---

## Sources

### Primary (HIGH confidence)

- `modelstore/cmd/init.sh` — scan_hf_models() and scan_ollama_models() patterns (source of truth for adapter enumeration logic)
- `modelstore/lib/common.sh` — check_cold_mounted(), check_space(), validate_cold_fs() implementations
- `modelstore/lib/config.sh` — load_config(), write_config() patterns; MODELSTORE_CONFIG path
- `.planning/phases/02-adapters-and-usage-tracking/02-CONTEXT.md` — all locked implementation decisions
- `.planning/research/ARCHITECTURE.md` — HF cache layout, Ollama blob/manifest structure, atomic symlink pattern
- `.planning/research/STACK.md` — inotify-tools, flock, rsync version compatibility on DGX
- `.planning/research/PITFALLS.md` — Ollama server restart requirement, HF migration unit rule, space check formula
- [inotify-tools man page / linuxbash.sh](https://www.linuxbash.sh/post/monitoring-file-changes-with-inotifywait) — `-m -e access` event mask (MEDIUM, consistent with stack research)

### Secondary (MEDIUM confidence)

- [docker events docs](https://docs.docker.com/reference/cli/docker/system/events/) — `--filter event=start`, `--format '{{json .}}'` output schema
- [flock man page](https://man7.org/linux/man-pages/man1/flock.1.html) — file descriptor locking, lock file pattern

### Tertiary (LOW confidence)

- Docker event JSON field paths for container args — not independently verified; needs testing on actual DGX to confirm `Actor.Attributes` fields available for vLLM containers.

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all tools verified in Phase 1 or prior stack research; inotify-tools confirmed in apt
- Architecture: HIGH — adapter patterns directly derived from existing Phase 1 code; no new algorithms
- Ollama migrate stub: MEDIUM — `ollama cp` to arbitrary path not verified (STATE.md blocker); Phase 2 implements guards only
- Docker event parsing: LOW — field paths need verification on actual DGX with running vLLM container
- Pitfalls: HIGH — derived from existing pitfalls research and Phase 1 implementation experience

**Research date:** 2026-03-21
**Valid until:** 2026-04-20 (stable domain; inotifywait and docker events APIs are stable)
