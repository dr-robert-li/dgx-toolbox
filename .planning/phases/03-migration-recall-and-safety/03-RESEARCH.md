# Phase 3: Migration, Recall, and Safety - Research

**Researched:** 2026-03-21
**Domain:** Bash-based cron migration, synchronous recall, flock concurrency guards, disk warnings, dry-run, JSON audit log
**Confidence:** HIGH (all critical patterns verified against existing Phase 2 code and prior research)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Recall trigger behavior**
- Both automatic and manual recall: watcher daemon auto-recalls on cold symlink access + `modelstore recall <model>` for explicit control
- Models on cold storage remain loadable via symlink (slower but functional) — recall moves them back to hot for speed
- Recall is synchronous (block and wait) — the model consumer waits until recall completes, then loads normally. No background recall.
- A 24GB model recall may take minutes — acceptable tradeoff vs failing or loading slowly from cold

**Dry-run output format**
- `modelstore migrate --dry-run` shows a full table: model name, size, last used, days since use, source→destination
- Also shows total size to be moved and available space on cold drive
- Additionally shows models that WON'T be migrated and why ("used within 14 days", "already on cold", etc.)
- Two sections: "Would migrate" and "Keeping hot"

**Disk warning notifications**
- Frequency: fire once when 98% threshold crossed, suppress until usage drops below 98% (no daily nagging)
- Track suppression state in `~/.modelstore/disk_alert_sent_<drive_hash>` marker files
- Content: specific and actionable — "Hot storage at 98.5% (3.64TB/3.7TB). Run: modelstore migrate"
- Desktop: `notify-send` with `DBUS_SESSION_BUS_ADDRESS` injection from cron
- Fallback log: `~/.modelstore/alerts.log` when no desktop session available

**Audit log format**
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

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope.

</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| MIGR-01 | Daily cron job migrates models unused beyond retention period from hot to cold store using rsync | `migrate_cron.sh` wraps `cmd/migrate.sh`; `install_cron()` in init.sh sets `0 ${CRON_HOUR} * * * cron/migrate_cron.sh` |
| MIGR-02 | Migrated models are replaced with symlinks so all paths remain valid | `hf_migrate_model()` already does atomic symlink swap; Ollama stub needs body in Phase 3 |
| MIGR-03 | Symlink replacement is atomic (ln + mv -T pattern, no broken window) | `ln -s "$cold_target" "${model_id}.new" && mv -T "${model_id}.new" "$model_id"` pattern confirmed in hf_adapter.sh |
| MIGR-04 | HuggingFace models are migrated as whole `models--*/` directories | `hf_migrate_model()` already migrates the full `models--org--name/` directory unit |
| MIGR-05 | Ollama models migrated with manifest-aware blob reference counting | `ollama_migrate_model()` is a stub — Phase 3 must implement manifest parsing + blob ref-count logic |
| MIGR-06 | Concurrent migrations prevented via flock | `flock -n` on a lockfile at start of `migrate_cron.sh`; inner flock for usage.json already shown in watcher.sh |
| MIGR-07 | User can run dry-run mode to see what would migrate without moving data | `cmd/migrate.sh --dry-run` flag: collect stale list, print table, exit 0 without touching any data |
| MIGR-08 | All migration and recall operations logged to audit file | `audit_log()` helper writes JSON line to `~/.modelstore/audit.log` with annual rotation check |
| RECL-01 | When a model is actively needed it is moved back from cold to hot store automatically | Watcher's inotify detects cold symlink access, calls `cmd/recall.sh`; synchronous block-and-wait |
| RECL-02 | Recall replaces the symlink with real files and resets the retention timer | `hf_recall_model()` already does this; Ollama stub needs body |
| RECL-03 | Launcher hooks trigger recall and update usage timestamps | Watcher daemon triggers recall on inotify access event; manual `modelstore recall <model>` path |
| SAFE-03 | Cron sends desktop notification via `notify-send` if either drive exceeds 98% usage | `disk_check_cron.sh` calls `notify_user()` from `lib/notify.sh`; uses marker file suppression |
| SAFE-04 | Notifications fall back to log file when desktop session unavailable | `notify_user()` writes to `~/.modelstore/alerts.log` if `DBUS_SESSION_BUS_ADDRESS` detection fails |
| SAFE-05 | All multi-step operations use a state file for interrupt-safe, idempotent resumption | State file `~/.modelstore/op_state.json` tracks in-progress operation; checked at start of migrate/recall |

</phase_requirements>

---

## Summary

Phase 3 builds on fully functional Phase 2 adapters. The `hf_migrate_model()` and `hf_recall_model()` functions in `hf_adapter.sh` are complete and correct — Phase 3 does NOT rewrite them, it calls them. The Ollama adapter has correct guard structure but empty bodies for migrate/recall — Phase 3 fills those bodies with manifest-aware blob migration logic.

The three new files that need to be created from scratch are `cmd/migrate.sh`, `cmd/recall.sh`, and `lib/notify.sh`. Two thin cron wrappers (`cron/migrate_cron.sh`, `cron/disk_check_cron.sh`) are also new. The watcher daemon in `hooks/watcher.sh` needs to be extended to detect cold symlink access and trigger recall.

The audit log and state file are new infrastructure. The audit log uses the same `flock`+`jq` atomic write pattern already proven in `ms_track_usage()`. The state file provides interrupt safety for the multi-step migrate/recall sequences, enabling idempotent re-runs.

**Primary recommendation:** Build in order: `lib/notify.sh` → `lib/audit.sh` helper → `cmd/migrate.sh` (HF only, then Ollama) → `cmd/recall.sh` → `cron/migrate_cron.sh` → `cron/disk_check_cron.sh` → watcher recall trigger. Reuse every existing function; add to, never rewrite, the adapters.

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| rsync | 3.2.7 (on host) | Cross-filesystem file migration | Already used in `hf_migrate_model()`; `--remove-source-files` makes it safe for atomic moves |
| flock | util-linux (on host) | Prevent concurrent cron runs | `flock -n lockfile cmd` exits immediately if lock held; auto-releases on crash |
| jq | system | JSON read/write for audit log + state file | Already used throughout for usage.json, config.json |
| notify-send | libnotify (on host) | Desktop disk-usage alerts | Already on GNOME DGX Spark; requires DBUS env injection from cron |
| inotifywait | 3.22.6.0 (apt) | Detect cold symlink access for auto-recall | Already used in watcher.sh for usage tracking |
| date | coreutils (system) | ISO-8601 timestamps for audit log | `date -u +%Y-%m-%dT%H:%M:%SZ` and `date +%Y` for rotation year |
| df | coreutils (system) | Disk usage percentage for 98% threshold check | `df --output=pcent,avail,size -B1 "$path" \| tail -1` |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| pgrep | procps (system) | Find gnome-session PID for DBUS address | Used in `notify_user()` to locate running desktop session |
| findmnt | util-linux (system) | Already used in `validate_cold_fs()` | Needed in disk check to enumerate both hot and cold mount points |
| md5sum / sha256sum | coreutils | Stable drive hash for marker file name | `disk_alert_sent_<drive_hash>` — hash the cold_path string |

**Installation:** No new packages required. All tools are on host.

---

## Architecture Patterns

### Recommended File Structure for Phase 3

```
modelstore/
├── cmd/
│   ├── migrate.sh          # NEW: migration logic + --dry-run flag
│   └── recall.sh           # NEW: recall logic (synchronous, block-and-wait)
├── cron/
│   ├── migrate_cron.sh     # NEW: thin cron wrapper for daily migration
│   └── disk_check_cron.sh  # NEW: thin cron wrapper for 98% disk check
└── lib/
    ├── notify.sh            # NEW: notify-send with DBUS injection + log fallback
    ├── audit.sh             # NEW: audit_log() helper, annual rotation logic
    ├── hf_adapter.sh        # EXISTING: hf_migrate_model + hf_recall_model (call as-is)
    ├── ollama_adapter.sh    # EXTEND: fill ollama_migrate_model + ollama_recall_model bodies
    ├── common.sh            # EXISTING: check_cold_mounted, check_space, ms_log, ms_die
    └── config.sh            # EXISTING: load_config → HOT_HF_PATH, COLD_PATH, RETENTION_DAYS
```

### Pattern 1: cmd/migrate.sh Structure

**What:** Top-level migration command that orchestrates stale model detection, guards, dry-run rendering, and adapter calls.

**When to use:** Called by `migrate_cron.sh` (cron trigger) and by `modelstore migrate` (manual trigger, Phase 4).

```bash
#!/usr/bin/env bash
# cmd/migrate.sh — Hot→cold migration for stale models
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/config.sh"
source "${SCRIPT_DIR}/../lib/hf_adapter.sh"
source "${SCRIPT_DIR}/../lib/ollama_adapter.sh"
source "${SCRIPT_DIR}/../lib/audit.sh"

DRY_RUN=false
TRIGGER="manual"
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true
[[ "${TRIGGER_SOURCE:-}" == "cron" ]] && TRIGGER="cron"

load_config

# Collect stale models from usage.json (age > RETENTION_DAYS)
# For each stale model:
#   $DRY_RUN: add to "would migrate" table, skip actual move
#   !$DRY_RUN: call hf_migrate_model / ollama_migrate_model, audit_log each result
```

**Dry-run table format:**

```
Would migrate (3 models, 47.2 GB total):
  MODEL                          SIZE     LAST USED     DAYS AGO  ACTION
  meta-llama/Llama-3.2-8B        24.1 GB  2026-01-15    65 days   hot -> cold
  mistralai/Mistral-7B-v0.1      14.4 GB  2026-02-01    48 days   hot -> cold
  deepseek-ai/DeepSeek-R1-8B      8.7 GB  2025-12-20    91 days   hot -> cold

Keeping hot (2 models):
  MODEL                          SIZE     LAST USED     REASON
  meta-llama/Llama-3.3-70B       42.5 GB  2026-03-20    used within 14 days
  models--qwen--Qwen2-7B          9.1 GB  ---           already on cold

Cold store available: 412 GB / 1.0 TB
```

### Pattern 2: Stale Model Detection from usage.json

**What:** Read `~/.modelstore/usage.json` (maintained by watcher.sh), compare each model's last timestamp against `RETENTION_DAYS`.

```bash
# Source: watcher.sh usage.json schema — {"<model_path>": "ISO-8601-timestamp", ...}
find_stale_models() {
  local retention_days="$1"
  local cutoff_epoch
  cutoff_epoch=$(date -d "${retention_days} days ago" +%s)

  jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$USAGE_FILE" 2>/dev/null \
  | while IFS=$'\t' read -r model_path last_used; do
      local last_epoch
      last_epoch=$(date -d "$last_used" +%s 2>/dev/null || echo 0)
      if [[ "$last_epoch" -lt "$cutoff_epoch" ]]; then
        echo "$model_path"
      fi
    done
}
```

**Also enumerate models not in usage.json:** Walk `HOT_HF_PATH/models--*/` — models with no usage record are treated as stale (no timestamp = never tracked = safe to migrate).

### Pattern 3: flock-Based Concurrency Guard

**What:** Prevent two cron invocations of migrate from overlapping. Uses `flock -n` — non-blocking, fails immediately if lock held.

**Discretion decision (as recommended):**
- Lock file: `~/.modelstore/migrate.lock`
- Fail mode: log a message and exit 0 (do not alarm the cron system with non-zero exit when simply skipping)

```bash
# In migrate_cron.sh
LOCK_FILE="${HOME}/.modelstore/migrate.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  ms_log "Migration already running (lock held). Skipping."
  exit 0
fi
# Lock auto-releases when the script exits (fd 9 closes)
```

**Note:** This is different from watcher.sh's inner flock on usage.json. The outer migration lock uses `exec 9>` + `flock -n 9` pattern (recommended by util-linux docs) rather than a subshell flock, so it applies for the script's entire lifetime.

### Pattern 4: Audit Log Helper (lib/audit.sh)

**What:** Single `audit_log()` function that writes a JSON line to `~/.modelstore/audit.log` with annual rotation.

**Rotation logic:** At each write, check if current year differs from log's year (by reading first line's timestamp). If rotated year detected, rename current log to `audit.<year>.log` before writing.

```bash
# Source: watcher.sh ms_track_usage pattern adapted for audit
AUDIT_LOG="${HOME}/.modelstore/audit.log"
AUDIT_LOCK="${HOME}/.modelstore/audit.lock"

audit_log() {
  local event="$1" model="$2" size_bytes="$3" source="$4" dest="$5"
  local duration_sec="$6" trigger="$7" error="${8:-null}"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Annual rotation check
  _audit_rotate_if_needed

  local entry
  entry=$(jq -cn \
    --arg ts "$timestamp" \
    --arg ev "$event" \
    --arg mo "$model" \
    --argjson sz "$size_bytes" \
    --arg src "$source" \
    --arg dst "$dest" \
    --argjson dur "$duration_sec" \
    --arg tr "$trigger" \
    --arg err "$error" \
    '{timestamp:$ts, event:$ev, model:$mo, size_bytes:$sz,
      source:$src, dest:$dst, duration_sec:$dur,
      trigger:$tr, error:(if $err == "null" then null else $err end)}')

  # Atomic append under flock (same pattern as ms_track_usage)
  (
    flock -x 9
    echo "$entry" >> "$AUDIT_LOG"
  ) 9>"$AUDIT_LOCK"
}

_audit_rotate_if_needed() {
  [[ -f "$AUDIT_LOG" ]] || return 0
  local current_year log_year
  current_year=$(date +%Y)
  log_year=$(jq -r '.timestamp' "$AUDIT_LOG" 2>/dev/null | head -1 | cut -c1-4)
  [[ -z "$log_year" || "$log_year" == "$current_year" ]] && return 0
  mv "$AUDIT_LOG" "${AUDIT_LOG%.log}.${log_year}.log"
}
```

### Pattern 5: State File for Interrupt-Safe Operations (SAFE-05)

**Discretion decision (recommended):** Use `~/.modelstore/op_state.json` as a lightweight in-progress marker. Format:

```json
{
  "op": "migrate|recall",
  "model": "/path/to/model",
  "phase": "rsync|symlink|cleanup",
  "started_at": "ISO-8601",
  "trigger": "cron|manual|auto"
}
```

**Protocol:**
1. Write state file BEFORE starting multi-step operation
2. Update `phase` field as each step completes
3. Delete state file AFTER operation completes (success or logged failure)
4. On startup, if state file exists: log warning "Resuming interrupted operation", re-run from last recorded phase

**Implementation detail:** Use atomic write (jq output to `.tmp` + `mv`) so state file is never partially written.

```bash
_write_op_state() {
  local op="$1" model="$2" phase="$3" trigger="$4"
  jq -cn --arg op "$op" --arg m "$model" --arg ph "$phase" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg tr "$trigger" \
    '{op:$op, model:$m, phase:$ph, started_at:$ts, trigger:$tr}' \
    > "${OP_STATE_FILE}.tmp"
  mv "${OP_STATE_FILE}.tmp" "$OP_STATE_FILE"
}
_clear_op_state() { rm -f "$OP_STATE_FILE"; }
```

### Pattern 6: notify-send from Cron with Suppression (SAFE-03/04)

**What:** `lib/notify.sh` provides `notify_user()` that injects DBUS env vars. `disk_check_cron.sh` calls this with suppression marker file logic.

**DBUS detection method (recommended):** Read from `/proc/<gnome-session-pid>/environ`. This is the most reliable approach for Ubuntu/GNOME. Falls back to `XDG_RUNTIME_DIR/bus` socket path as secondary.

```bash
# Source: ARCHITECTURE.md Pattern 5 (verified MEDIUM confidence)
notify_user() {
  local summary="$1" body="$2"
  local uid
  uid=$(id -u)
  local dbus_addr=""
  local gnome_pid
  gnome_pid=$(pgrep -u "$uid" gnome-session 2>/dev/null | head -1)
  if [[ -n "$gnome_pid" ]]; then
    dbus_addr=$(grep -z DBUS_SESSION_BUS_ADDRESS \
      "/proc/${gnome_pid}/environ" 2>/dev/null \
      | tr -d '\0' | sed 's/DBUS_SESSION_BUS_ADDRESS=//')
  fi
  # Fallback: well-known systemd user bus socket
  [[ -z "$dbus_addr" ]] && dbus_addr="unix:path=/run/user/${uid}/bus"

  if DISPLAY=":0" XDG_RUNTIME_DIR="/run/user/${uid}" \
     DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
     notify-send --app-name="modelstore" "$summary" "$body" 2>/dev/null; then
    return 0
  fi
  # Fallback: write to alerts.log
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $summary — $body" \
    >> "${HOME}/.modelstore/alerts.log"
}
```

**Suppression marker file:** Drive hash is the md5 of the canonical path string.

```bash
# In disk_check_cron.sh
check_disk_threshold() {
  local path="$1"
  local pct
  pct=$(df --output=pcent "$path" | tail -1 | tr -d ' %')
  local drive_hash
  drive_hash=$(echo "$path" | md5sum | cut -d' ' -f1)
  local marker="${HOME}/.modelstore/disk_alert_sent_${drive_hash}"

  if [[ "$pct" -ge 98 ]]; then
    if [[ ! -f "$marker" ]]; then
      local avail total
      avail=$(df -BG --output=avail "$path" | tail -1 | tr -d ' G')
      total=$(df -BG --output=size "$path" | tail -1 | tr -d ' G')
      notify_user "modelstore: disk warning" \
        "Storage at ${pct}% (${avail}GB free / ${total}GB). Run: modelstore migrate"
      audit_log "disk_warning" "$path" 0 "$path" "" 0 "cron" "null"
      touch "$marker"
    fi
  else
    # Usage dropped below threshold — remove suppression marker
    rm -f "$marker"
  fi
}
```

### Pattern 7: Ollama Adapter Body (MIGR-05)

**What:** Fill in `ollama_migrate_model()` and `ollama_recall_model()` in `ollama_adapter.sh`. The existing stubs already have correct guards (SAFE-06 server check, SAFE-01 mount check, SAFE-02 space check).

**Ollama storage layout (confirmed from ARCHITECTURE.md):**

```
~/.ollama/models/
  manifests/registry.ollama.ai/library/<model>/<tag>  ← JSON
  blobs/sha256-<hex>                                   ← blob files
```

**Blob reference-counting protocol (MIGR-05):**
1. Parse the model's manifest JSON: extract all `digest` fields from the `layers` and `config` arrays
2. For each blob digest: scan ALL manifests on hot store to count references
3. Only migrate a blob if its hot-store reference count will drop to 0 after this model's manifest moves
4. Move manifest file, then qualifying blobs, then create symlinks for each

```bash
# Parse blob digests from a manifest file
_ollama_manifest_blobs() {
  local manifest_file="$1"
  jq -r '([.layers[].digest] + [.config.digest]) | .[]' "$manifest_file" 2>/dev/null \
    | sed 's|sha256:|sha256-|'
}

# Count how many hot manifests reference a given blob digest
_ollama_blob_hot_refs() {
  local digest="$1"  # format: sha256-<hex>
  local sha="${digest#sha256-}"
  grep -rl "\"sha256:${sha}\"" "${HOT_OLLAMA_PATH}/models/manifests/" 2>/dev/null | wc -l
}
```

**Cold path layout for Ollama:**
```
$COLD_PATH/ollama/models/manifests/registry.ollama.ai/library/<model>/<tag>
$COLD_PATH/ollama/models/blobs/sha256-<hex>
```

### Pattern 8: Watcher Auto-Recall Trigger

**What:** Extend `watcher.sh` to detect when a cold symlink is accessed (inotify fires on a path that is a symlink pointing to cold) and call `cmd/recall.sh` synchronously.

**Implementation approach:** In `watch_inotify()` after extracting `model_path`, check if the path is a symlink pointing outside of `HOT_HF_PATH` or `HOT_OLLAMA_PATH` (i.e., points to `COLD_PATH`). If so, call `cmd/recall.sh` blocking.

```bash
# In watcher.sh watch_inotify() loop (addition to existing code)
if [[ -L "$model_path" ]]; then
  local link_target
  link_target=$(readlink -f "$model_path" 2>/dev/null || true)
  if [[ "$link_target" == "${COLD_PATH}"/* ]]; then
    ms_log "Cold symlink access detected: $model_path — triggering recall"
    "${SCRIPT_DIR}/../cmd/recall.sh" "$model_path" --trigger=auto 2>/dev/null || \
      ms_log "Auto-recall failed for $model_path"
  fi
fi
```

**Note:** Recall is synchronous by design — `cmd/recall.sh` blocks until complete. The watcher loop will not process the next inotify event until recall finishes. This is acceptable and required per the locked decision.

### Anti-Patterns to Avoid

- **Do not rewrite hf_migrate_model / hf_recall_model.** They are complete and correct. Call them.
- **Do not call the CLI dispatcher from cron.** `migrate_cron.sh` must call `cmd/migrate.sh` directly.
- **Do not use `rm -rf` on any path without checking `[[ ! -L "$path" ]]` first.** The cleanup step after rsync uses `find -type d -empty -delete` — this is already correct in hf_adapter.sh.
- **Do not rotate audit log by size.** Rotation is annual (year boundary), keep all old files forever.
- **Do not move Ollama blobs that are still referenced by other hot manifests.** Reference counting is mandatory per MIGR-05.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Atomic symlink swap | Custom temp-file swap | `ln -s target path.new && mv -T path.new path` | Already proven in hf_adapter.sh; mv -T calls rename(2) which is atomic |
| Cross-filesystem file move | `cp` + `rm` | `rsync -a --remove-source-files` | rsync only deletes source after successful transfer; cp+rm leaves orphan on crash |
| Concurrent lock | PID file + kill -0 | `flock -n lockfile` | flock auto-releases on crash; no stale-PID cleanup needed |
| JSON atomic write | Direct append to file | `jq ... > file.tmp && mv file.tmp file` | Direct append is not atomic; partial writes corrupt JSON |
| Drive usage check | `du -sh` on model dirs | `df --output=pcent,avail,size -B1 "$path"` | `du` measures source blocks not dest space; df measures actual available bytes |
| DBUS session discovery | Hardcoding socket path | `/proc/<gnome-session-pid>/environ` grep | Hardcoded paths fail if UID changes or multiple sessions exist |

---

## Common Pitfalls

### Pitfall 1: Ollama Blob Shared Reference Deletion

**What goes wrong:** Migrating model A's blobs when model B shares some of those blobs — model B breaks silently.

**Why it happens:** Ollama uses content-addressed blob storage; a `sha256-<hex>` blob may appear in multiple model manifests.

**How to avoid:** Always scan all hot manifests for reference count before moving any blob. Only move a blob when its hot reference count drops to 0.

**Warning signs:** `ollama run <other_model>` fails after migration of a different model with "model not found" or blob errors.

### Pitfall 2: notify-send Silent Failure from Cron

**What goes wrong:** `notify-send` is called from cron without DBUS session env vars — silently fails, no desktop notification, user never sees disk warning.

**Why it happens:** Cron runs in a minimal environment with no desktop session context.

**How to avoid:** Always grep `DBUS_SESSION_BUS_ADDRESS` from running gnome-session's `/proc/<pid>/environ`. Test by running the cron script via `crontab -e` (not manually as user) and checking if notification appears.

**Warning signs:** Running `notify-send "test" "msg"` in a cron test shows no desktop popup but no error either.

### Pitfall 3: Stale State File Blocks All Operations

**What goes wrong:** A `kill -9` during migration leaves `op_state.json` on disk. Next cron run sees the state file and either skips the operation or enters a loop.

**Why it happens:** State file protocol writes before action, deletes after — a hard kill prevents deletion.

**How to avoid:** On startup, if state file exists AND `started_at` is older than 4 hours (configurable), treat as stale crash and log a warning + clear it. Never block indefinitely on a stale state file.

**Warning signs:** Migration stops running after a system crash.

### Pitfall 4: flock Lock File Permission Issue

**What goes wrong:** `~/.modelstore/migrate.lock` is created by one invocation then inaccessible to another if permissions are wrong.

**Why it happens:** The lock file is created with default umask; if the cron user differs from the interactive user, flock fails.

**How to avoid:** Create `~/.modelstore/migrate.lock` with `chmod 600` during init. The lock file is user-home-relative so this only affects single-user scenarios. All operations run as the same user.

### Pitfall 5: Dry-Run Reads from Wrong Source for "Already on Cold"

**What goes wrong:** Dry-run shows a model as "Would migrate" but it's already a symlink (already on cold). The run then skips it.

**Why it happens:** Dry-run enumeration must check `[[ -L "$model_path" ]]` exactly like the real migrate path. If dry-run enumerates all HF dirs without the symlink check, it misclassifies already-migrated models.

**How to avoid:** The dry-run collection function must share the same pre-flight checks as the real migration function: check symlink status first.

### Pitfall 6: RECL-03 Watcher Recall During Active Inference

**What goes wrong:** Model is being loaded by vLLM (file reads in progress), inotify fires, watcher triggers recall, `cmd/recall.sh` removes the symlink and starts rsync back to hot — but vLLM has open file descriptors to the cold path that now get deleted.

**Why it happens:** inotify fires on file `open`, which happens before the file is fully read. Recall removes cold files while vLLM is still reading them.

**How to avoid:** In the recall auto-trigger path, check `fuser "$model_path" 2>/dev/null` or `lsof +D "$cold_target" 2>/dev/null` before starting recall. If files are in use, skip and re-check in 60 seconds. For the manual recall path, document that the user should stop inference first.

**Note from prior research:** `lsof +D` is slow on large model directories. Use `fuser -s "$cold_target"` as a faster first check.

---

## Code Examples

### Stale Model Detection (reading usage.json)

```bash
# Source: watcher.sh usage.json schema + date arithmetic
# usage.json: {"<absolute_model_path>": "2026-01-15T03:00:00Z", ...}
find_stale_hf_models() {
  local retention_days="$1"
  local cutoff_epoch
  cutoff_epoch=$(date -d "${retention_days} days ago" +%s)

  # Models in usage.json past retention
  if [[ -f "$USAGE_FILE" ]]; then
    jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$USAGE_FILE" 2>/dev/null \
    | while IFS=$'\t' read -r model_path last_used; do
        [[ "$model_path" != "${HOT_HF_PATH}/models--"* ]] && continue
        [[ -L "$model_path" ]] && continue  # already migrated
        local last_epoch
        last_epoch=$(date -d "$last_used" +%s 2>/dev/null || echo 0)
        [[ "$last_epoch" -lt "$cutoff_epoch" ]] && echo "$model_path"
      done
  fi

  # Models not in usage.json at all (never tracked = treat as stale)
  for model_dir in "${HOT_HF_PATH}"/models--*/; do
    [[ -d "$model_dir" && ! -L "${model_dir%/}" ]] || continue
    local key="${model_dir%/}"
    if ! jq -e --arg k "$key" 'has($k)' "$USAGE_FILE" &>/dev/null; then
      echo "$key"
    fi
  done
}
```

### Audit Log Write

```bash
# Source: adapted from ms_track_usage() flock pattern in watcher.sh
# All numeric fields must be integers (not strings) for machine parsing
audit_log() {
  local event="$1" model="$2" size_bytes="${3:-0}" source="${4:-}" dest="${5:-}"
  local duration_sec="${6:-0}" trigger="${7:-manual}" error="${8:-null}"

  _audit_rotate_if_needed

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local entry
  entry=$(jq -cn \
    --arg ts "$ts" --arg ev "$event" --arg mo "$model" \
    --argjson sz "${size_bytes}" --arg src "$source" --arg dst "$dest" \
    --argjson dur "${duration_sec}" --arg tr "$trigger" \
    '{timestamp:$ts,event:$ev,model:$mo,size_bytes:$sz,
      source:$src,dest:$dst,duration_sec:$dur,trigger:$tr,
      error:null}')

  (flock -x 9; echo "$entry" >> "$AUDIT_LOG") 9>"$AUDIT_LOCK"
}
```

### Cron Wrapper Pattern (migrate_cron.sh)

```bash
#!/usr/bin/env bash
# cron/migrate_cron.sh — Daily migration cron wrapper
# Called directly by crontab: 0 ${CRON_HOUR} * * * /path/to/cron/migrate_cron.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_FILE="${HOME}/.modelstore/migrate.lock"

# Acquire exclusive lock — skip if already running
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[modelstore] Migration already running. Skipping." >&2
  exit 0
fi

# Delegate to cmd/migrate.sh with cron trigger marker
TRIGGER_SOURCE=cron exec "${SCRIPT_DIR}/../cmd/migrate.sh"
```

### Recall Script Pattern (cmd/recall.sh)

```bash
#!/usr/bin/env bash
# cmd/recall.sh — Synchronous recall of a model from cold to hot storage
# Usage: recall.sh <model_path> [--trigger=manual|auto]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/config.sh"
source "${SCRIPT_DIR}/../lib/hf_adapter.sh"
source "${SCRIPT_DIR}/../lib/ollama_adapter.sh"
source "${SCRIPT_DIR}/../lib/audit.sh"

MODEL_PATH="${1:?Usage: recall.sh <model_path>}"
TRIGGER="manual"
[[ "${2:-}" == "--trigger=auto" ]] && TRIGGER="auto"
[[ "${2:-}" == "--trigger=cron" ]] && TRIGGER="cron"

load_config
OP_STATE_FILE="${HOME}/.modelstore/op_state.json"

# Resume check: if op_state.json exists for this model, resume from last phase
# ...

start_epoch=$(date +%s)
if [[ "$MODEL_PATH" == "${HOT_HF_PATH}/models--"* ]]; then
  hf_recall_model "$MODEL_PATH" "$HOT_HF_PATH"
elif [[ "$MODEL_PATH" == "${HOT_OLLAMA_PATH}"/* ]]; then
  ollama_recall_model "$MODEL_PATH" "$HOT_OLLAMA_PATH"
fi
end_epoch=$(date +%s)
duration=$(( end_epoch - start_epoch ))

audit_log "recall" "$MODEL_PATH" 0 "$COLD_PATH" "$HOT_HF_PATH" "$duration" "$TRIGGER"
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Polling loop for recall trigger | inotifywait `-e access,open` | Phase 2 (watcher.sh) | Zero CPU when idle; sub-ms response |
| `cp` + `rm` for migration | `rsync --remove-source-files` | Phase 2 (hf_adapter.sh) | Crash-safe: source only deleted after successful transfer |
| Direct `ln -s` replace | `ln -s target path.new && mv -T` | Phase 2 (hf_adapter.sh) | Atomic: no window where path is absent |
| `atime` for stale detection | Explicit usage.json manifest | Phase 2 (watcher.sh) | Reliable regardless of mount options |

---

## Open Questions

1. **RECL-01 / watcher race: recall while model is loading**
   - What we know: inotify fires on `open`, but vLLM may hold the file open for minutes during load
   - What's unclear: Whether `fuser -s` is fast enough as a pre-recall guard vs the 30-second timeout penalty
   - Recommendation: Add `fuser -s "$cold_target" 2>/dev/null` check before recall; if busy, log and skip (do not retry in watcher — next inotify event will retrigger). Document the edge case.

2. **Ollama manifest JSON field paths (MIGR-05)**
   - What we know: Architecture research confirms `layers[].digest` and `config.digest` are the blob reference fields
   - What's unclear: Exact field names in practice on this DGX (STATE.md flags this as unverified)
   - Recommendation: Implementer must run `cat ~/.ollama/models/manifests/registry.ollama.ai/library/<any_model>/<tag>` on the actual DGX before writing the jq filter. Use `jq '.' manifest.json | head -50` to verify.

3. **DBUS injection on aarch64 Ubuntu (SAFE-03)**
   - What we know: `pgrep -u $uid gnome-session` + `/proc/<pid>/environ` grep works on x86 Ubuntu
   - What's unclear: STATE.md flags MEDIUM confidence on aarch64 — gnome-session process name may differ
   - Recommendation: Fallback to `unix:path=/run/user/${uid}/bus` (systemd user bus socket, always present on Ubuntu 22+) as primary if gnome-session is absent. Test on actual DGX before committing.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Inline bash assertions (no bats dependency per STATE.md decision) |
| Config file | none — inline pattern per existing tests |
| Quick run command | `bash tests/test_migrate.sh` |
| Full suite command | `bash tests/test_migrate.sh && bash tests/test_recall.sh && bash tests/test_audit.sh && bash tests/test_disk_check.sh` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| MIGR-01 | Cron script runs without error when no stale models | smoke | `bash tests/test_migrate.sh::cron_no_stale` | Wave 0 |
| MIGR-02 | Migrated HF model path becomes a symlink | unit | `bash tests/test_migrate.sh::symlink_created` | Wave 0 |
| MIGR-03 | Symlink swap is atomic (no window where path absent) | unit | `bash tests/test_migrate.sh::atomic_swap` | Wave 0 |
| MIGR-04 | HF migration moves entire models--*/ directory | unit | `bash tests/test_migrate.sh::hf_whole_dir` | Wave 0 |
| MIGR-05 | Ollama shared blob not moved if referenced by other model | unit | `bash tests/test_migrate.sh::ollama_blob_refcount` | Wave 0 |
| MIGR-06 | Second migrate invocation skips when lock held | unit | `bash tests/test_migrate.sh::flock_skip` | Wave 0 |
| MIGR-07 | Dry-run prints table and makes no filesystem changes | unit | `bash tests/test_migrate.sh::dry_run` | Wave 0 |
| MIGR-08 | Audit log entry written after migration | unit | `bash tests/test_audit.sh::migrate_logged` | Wave 0 |
| RECL-01 | Auto-recall triggered by cold symlink access (watcher) | integration | `bash tests/test_recall.sh::auto_trigger` | Wave 0 |
| RECL-02 | Recall replaces symlink with real dir, resets timestamp | unit | `bash tests/test_recall.sh::symlink_replaced` | Wave 0 |
| RECL-03 | Launcher hook (inotify path) updates usage and triggers recall | integration | `bash tests/test_recall.sh::launcher_hook` | Wave 0 |
| SAFE-03 | notify-send called when disk >98% | unit | `bash tests/test_disk_check.sh::notify_threshold` | Wave 0 |
| SAFE-04 | alerts.log written when notify-send fails | unit | `bash tests/test_disk_check.sh::fallback_log` | Wave 0 |
| SAFE-05 | Interrupted migration resumes from correct phase | unit | `bash tests/test_migrate.sh::state_resume` | Wave 0 |

### Sampling Rate
- **Per task commit:** `bash tests/test_migrate.sh && bash tests/test_recall.sh`
- **Per wave merge:** Full suite above
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `tests/test_migrate.sh` — covers MIGR-01 through MIGR-07, SAFE-05
- [ ] `tests/test_recall.sh` — covers RECL-01, RECL-02, RECL-03
- [ ] `tests/test_audit.sh` — covers MIGR-08
- [ ] `tests/test_disk_check.sh` — covers SAFE-03, SAFE-04

---

## Sources

### Primary (HIGH confidence)
- `modelstore/lib/hf_adapter.sh` — existing migrate/recall code; source of truth for atomic symlink pattern
- `modelstore/lib/ollama_adapter.sh` — existing guards structure; Phase 3 fills bodies
- `modelstore/hooks/watcher.sh` — flock+jq atomic write pattern reused for audit log
- `modelstore/lib/common.sh` — check_cold_mounted, check_space, ms_log, ms_die (reused directly)
- `modelstore/lib/config.sh` — load_config, MODELSTORE_CONFIG, config schema
- `modelstore/cmd/init.sh:install_cron()` — cron file paths are `cron/migrate_cron.sh` and `cron/disk_cron.sh`; cron line format confirmed
- `.planning/research/ARCHITECTURE.md` — notify-send DBUS pattern (Pattern 5), data flow diagrams
- `.planning/research/PITFALLS.md` — Ollama server check requirement, fuser vs lsof recommendation
- `.planning/research/STACK.md` — flock pattern, rsync flags, tool versions confirmed on host

### Secondary (MEDIUM confidence)
- `.planning/phases/03-migration-recall-and-safety/03-CONTEXT.md` — all locked decisions; canonical reference for this phase
- `.planning/STATE.md` — accumulated decisions including atime unreliability, bash test inline pattern, PASS counter fix

### Tertiary (LOW confidence / needs on-device validation)
- Ollama manifest JSON field paths — `layers[].digest` + `config.digest` from Architecture research but unverified on actual DGX (flagged in STATE.md)
- DBUS injection on aarch64 Ubuntu — gnome-session process name may differ; fallback to systemd user bus socket recommended

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all tools confirmed on host from prior research, existing code confirms usage patterns
- Architecture: HIGH — hf_adapter.sh and watcher.sh provide proven patterns to copy; Ollama body is MEDIUM (field paths unverified on device)
- Pitfalls: HIGH — most pitfalls derived from existing code analysis + prior research, not speculation

**Research date:** 2026-03-21
**Valid until:** 2026-04-21 (stable bash/rsync domain; Ollama manifest schema could change if Ollama is updated)
