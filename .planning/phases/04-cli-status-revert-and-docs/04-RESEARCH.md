# Phase 4: CLI, Status, Revert, and Docs - Research

**Researched:** 2026-03-22
**Domain:** Bash CLI dispatcher, status dashboard, interrupt-safe revert, project reorganization, documentation
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Status output format:**
- Columns per model: name, ecosystem (HF/Ollama), tier (HOT/COLD/BROKEN), size, last used, days until migration
- Sorted by size (largest first)
- Full dashboard summary after model table:
  - Drive totals: "Hot: 26GB/3.7TB used, Cold: 0B/938GB used"
  - Model counts: "8 models hot, 0 cold, 0 broken"
  - Watcher status: running/stopped + PID
  - Cron status: installed/not installed + next run time
  - Last migration: timestamp or "never"

**Revert safety flow:**
- Default: preview what will be moved back (models, sizes, total), then prompt "Proceed? [y/N]"
- `--force` flag skips confirmation (for scripts/NVIDIA Sync)
- Cleanup scope after revert:
  - Remove modelstore/ directory on cold drive
  - Uninstall modelstore crontab entries
  - Stop watcher daemon, remove pidfile
  - KEEP `~/.modelstore/config.json` (makes reinit easier)
- Interrupt safety: resume from `op_state.json` — tracks which models already reverted, picks up where it left off on re-run

**Documentation scope:**
- README: integrated "Model Store" section alongside existing sections (Inference, Data, Eval, etc.) with subcommands table + quick start
- Aliases: single `modelstore` alias only — subcommands handle the rest. Add to both `~/.bash_aliases` and `example.bash_aliases` with description comment.
- NVIDIA Sync: add a custom app entry that runs `modelstore status` and returns output (CLI tool, no port)
- CHANGELOG: add modelstore release entry
- .gitignore: exclude modelstore runtime artifacts (`~/.modelstore/` is outside repo, but any test fixtures or temp files inside repo should be ignored)

**Project root reorganization:**
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

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| CLI-01 | Single `modelstore` CLI entry point dispatches to subcommands: init, status, recall, revert, migrate | modelstore.sh case statement already routes init/status/migrate/recall/revert; just needs status.sh and revert.sh created |
| CLI-02 | Individual scripts exist for cron and NVIDIA Sync integration | cron/ scripts already exist from Phase 3; Sync entry in README for `modelstore status` (no port, CLI tool) |
| CLI-03 | `modelstore status` shows what's on each tier with sizes, last-used timestamps, and space available | Build cmd/status.sh using hf_list_models + ollama_list_models + usage.json + watcher pidfile + crontab query |
| CLI-04 | `modelstore revert` moves all models back to internal, removes all symlinks, undoes all tiering | Build cmd/revert.sh with preview/confirm flow, op_state.json tracking, cleanup (cron + watcher + cold dir) |
| CLI-05 | Revert is interrupt-safe and idempotent (can be re-run if interrupted) | op_state.json schema for revert: array of reverted models + completion flags; same stale-state logic as migrate.sh |
| CLI-06 | Large migrations show progress bars (pv/rsync --info=progress2) | rsync --info=progress2 already used in Phase 3 adapters; add --info=progress2 flag when stdout is a TTY (headless guard) |
| CLI-07 | Non-interactive commands work headless for NVIDIA Sync (no TTY required) | --force flag on revert; test -t 1 (stdout is TTY) guard before prompts and progress bars |
| DOCS-01 | README updated with modelstore section, aliases, and NVIDIA Sync instructions | Add "Model Store" section to README.md with subcommands table, quick start, and Sync entry; update all script paths after reorg |
| DOCS-02 | CHANGELOG updated with modelstore release entry | Add top-level entry for Phase 4 (modelstore v1) in CHANGELOG.md |
| DOCS-03 | .gitignore updated for modelstore runtime artifacts | Add modelstore/test/fixtures/, modelstore/test/tmp*, *.lock patterns for in-repo test artifacts |
| DOCS-04 | example.bash_aliases updated with modelstore aliases | Add `modelstore` alias; update all script paths to subfolder locations after reorg |
</phase_requirements>

---

## Summary

Phase 4 is a finishing phase: all core modelstore logic (migrate, recall, cron, watcher) is complete. The remaining work falls into four concrete areas: (1) two new cmd/ scripts (`status.sh` and `revert.sh`), (2) wiring CLI-07 headless compatibility into the existing flow, (3) a file-move reorganization of the project root into category subfolders, and (4) atomic updates to all documentation and aliases that reference script paths.

The existing codebase is the primary reference: `op_state.json` interrupt safety, `hf_list_models` / `ollama_list_models` adapter functions, the `install_cron` pattern (which reveals exactly how to uninstall cron in revert), the watcher pidfile at `$HOME/.modelstore/watcher.pid`, and the printf table style from migrate.sh dry-run mode. No external libraries are needed — everything is pure bash + jq + standard POSIX tools already present on DGX Spark.

**Primary recommendation:** Implement status.sh and revert.sh first (they are the hardest pieces), then do the root reorganization as a single atomic commit, then update all docs/aliases in one final pass. Revert op_state.json schema must be designed before writing the revert loop — see the schema spec in Architecture Patterns below.

---

## Standard Stack

### Core
| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| bash | 5.x (system) | Script runtime | Project-wide constraint: bash only, no Python |
| jq | 1.6+ (system) | JSON read/write for op_state, usage.json, config.json | Already used throughout modelstore |
| rsync | 3.x (system) | File transfer with progress2 flag | Already used in hf_adapter.sh and ollama_adapter.sh |
| pv | system | Byte-level pipe progress | Available on DGX Spark; used in Phase 3 already |
| df | coreutils | Drive usage totals for status dashboard | Standard POSIX |
| crontab | system | Read and remove modelstore entries | Used in install_cron; same approach for removal |
| flock | util-linux | Concurrent operation guard | Used in migrate, recall, watcher, audit |

### No New Dependencies
This phase introduces zero new library dependencies. All tools are already present and validated in earlier phases.

---

## Architecture Patterns

### Recommended Project Structure (after root reorganization)

```
dgx-toolbox/
├── README.md
├── CHANGELOG.md
├── .gitignore
├── example.bash_aliases
├── example.vllm-model
├── lib.sh
├── modelstore.sh
├── modelstore/           (unchanged — Phase 1-3 work)
│   ├── cmd/
│   │   ├── init.sh
│   │   ├── migrate.sh
│   │   ├── recall.sh
│   │   ├── status.sh     (NEW — Phase 4)
│   │   └── revert.sh     (NEW — Phase 4)
│   ├── lib/
│   ├── cron/
│   ├── hooks/
│   └── test/
├── inference/            (moved from root)
│   ├── start-open-webui.sh
│   ├── start-open-webui-sync.sh
│   ├── start-vllm.sh
│   ├── start-vllm-sync.sh
│   ├── start-litellm.sh
│   ├── start-litellm-sync.sh
│   └── setup-litellm-config.sh
├── data/                 (moved from root)
│   ├── data-toolbox.sh
│   ├── data-toolbox-build.sh
│   ├── data-toolbox-jupyter.sh
│   ├── start-label-studio.sh
│   └── start-argilla.sh
├── eval/                 (moved from root)
│   ├── eval-toolbox.sh
│   ├── eval-toolbox-build.sh
│   ├── eval-toolbox-jupyter.sh
│   ├── triton-trtllm.sh
│   └── triton-trtllm-sync.sh
├── containers/           (moved from root)
│   ├── ngc-pytorch.sh
│   ├── ngc-jupyter.sh
│   ├── ngc-quickstart.sh
│   ├── unsloth-studio.sh
│   └── unsloth-studio-sync.sh
├── setup/                (moved from root)
│   ├── dgx-global-base-setup.sh
│   └── setup-ollama-remote.sh
├── build-toolboxes.sh    (kept in root — project-wide build)
├── status.sh             (kept in root — project-wide DGX status)
├── start-n8n.sh          (kept in root or move to containers/)
├── docker-compose.inference.yml
└── docker-compose.data.yml
```

**Key decision:** `lib.sh` stays in root because all launcher scripts source it via relative path (`source "$(dirname "$0")/../lib.sh"` or similar). Moving launcher scripts into subdirs means their source line needs to be `source "$(dirname "$0")/../lib.sh"` — one level up. Verify each script's source path when moving.

### Pattern 1: cmd/status.sh — Model Table + Dashboard

**What:** Read all models from both adapters, classify each as HOT/COLD/BROKEN, sort by size descending, print printf table, then print dashboard summary.

**Broken symlink detection:**
```bash
# A model is BROKEN if it is a symlink but readlink -f returns empty or nonexistent path
if [[ -L "$model_path" ]]; then
  target=$(readlink -f "$model_path" 2>/dev/null || true)
  if [[ -z "$target" || ! -e "$target" ]]; then
    tier="BROKEN"
  else
    tier="COLD"
  fi
else
  tier="HOT"
fi
```

**Cron status detection:**
```bash
# Check if any modelstore cron entry exists
if crontab -l 2>/dev/null | grep -q "modelstore"; then
  cron_status="installed"
  # Next run: extract hour from config
  next_run=$(crontab -l 2>/dev/null | grep "migrate_cron" | awk '{print $2}')
  echo "Cron: installed (next run ~${next_run}:00)"
else
  echo "Cron: not installed"
fi
```

**Watcher status detection:**
```bash
PIDFILE="${HOME}/.modelstore/watcher.pid"
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "Watcher: running (PID $(cat "$PIDFILE"))"
else
  echo "Watcher: stopped"
fi
```

**Drive totals via df:**
```bash
# Format: "Hot: 26GB/3.7TB used, Cold: 0B/938GB used"
hot_used=$(df -BG --output=used "$HOT_HF_PATH" | tail -1 | tr -d ' G')
hot_size=$(df -BG --output=size "$HOT_HF_PATH" | tail -1 | tr -d ' G')
```

**Days until migration calculation:**
```bash
last_used_epoch=$(date -d "$last_used" +%s 2>/dev/null || echo 0)
days_since=$(( ( $(date +%s) - last_used_epoch ) / 86400 ))
days_until=$(( RETENTION_DAYS - days_since ))
[[ "$days_until" -lt 0 ]] && days_until=0
```

### Pattern 2: cmd/revert.sh — Interrupt-Safe Revert

**op_state.json schema for revert (new, not shared with migrate/recall):**

The existing op_state.json schema tracks a single in-progress operation. For revert, which processes multiple models in sequence, the schema needs to track which models have already been reverted so re-runs skip completed work:

```json
{
  "op": "revert",
  "phase": "recall_hf|recall_ollama|cleanup_cron|cleanup_watcher|cleanup_cold_dir|done",
  "started_at": "2026-03-22T10:00:00Z",
  "trigger": "manual",
  "completed_models": ["/path/to/model1", "/path/to/model2"],
  "total_models": 5
}
```

**Key design:** `completed_models` is the idempotency list. On re-run, the revert loop skips any model whose path appears in `completed_models`. After recalling each model, the script re-writes op_state.json with the model appended to `completed_models`. This mirrors how migrate.sh uses `_write_op_state` + `_clear_op_state` but extended for a multi-model batch.

**Revert loop structure:**
```bash
# 1. Collect all migrated models (symlinks pointing to COLD_PATH)
mapfile -t migrated_hf < <(
  find "$HOT_HF_PATH" -maxdepth 1 -name "models--*" -type l 2>/dev/null | sort
)

# 2. Preview (unless --force or not a TTY)
if [[ "$FORCE" != "true" ]] && [[ -t 0 ]]; then
  # Print preview table, prompt "Proceed? [y/N]"
  # Default is N — user must explicitly confirm
fi

# 3. Recall loop with op_state tracking
for model_path in "${migrated_hf[@]}"; do
  # Skip already-completed (idempotent resume)
  if jq -e --arg m "$model_path" '.completed_models | index($m) != null' \
      "$OP_STATE_FILE" &>/dev/null 2>&1; then
    continue
  fi
  hf_recall_model "$model_path" "$(dirname "$model_path")"
  # Append to completed_models in op_state
  _append_completed "$model_path"
done

# 4. Cleanup
_write_op_state "revert" "" "cleanup_cron" "manual"
crontab -l 2>/dev/null | grep -v "modelstore" | crontab -

_write_op_state "revert" "" "cleanup_watcher" "manual"
if [[ -f "$PIDFILE" ]]; then
  kill "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -f "$PIDFILE"
fi

_write_op_state "revert" "" "cleanup_cold_dir" "manual"
# Remove modelstore/ subdirs from cold (hf/ and ollama/ only, not the cold root)
rm -rf "${COLD_PATH}/hf" "${COLD_PATH}/ollama" 2>/dev/null || true

# 5. Clear op_state (keep config.json)
_clear_op_state
```

**Headless / NVIDIA Sync compatibility (CLI-07):**
```bash
# At start of revert.sh
FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

# Before any interactive prompt:
if [[ "$FORCE" == "true" ]] || [[ ! -t 0 ]]; then
  # Skip confirmation, proceed immediately
  :
else
  # Prompt user
fi

# Before any progress bar output:
if [[ -t 1 ]]; then
  rsync -a --info=progress2 ...
else
  rsync -a ...
fi
```

**Note on `-t 0` vs `-t 1`:** Use `-t 0` (stdin is TTY) for interactive prompt guards. Use `-t 1` (stdout is TTY) for progress bar guards. When called via `nvidia-sync exec --`, neither stdin nor stdout is a TTY.

### Pattern 3: Root Reorganization — Atomic Path Update

**What goes wrong if done non-atomically:** Aliases reference old paths after scripts are moved but before aliases are updated — any user or Sync invocation during the window fails.

**Atomic approach:** Do the reorganization in a single git commit that includes:
1. `git mv` for each script to its new subdirectory
2. Updated `example.bash_aliases` with new paths
3. Updated `README.md` with new paths
4. Updated NVIDIA Sync table paths in README
5. Check `docker-compose.*.yml` for any script path references (currently neither compose file references root scripts directly — they use docker commands)
6. Check `lib.sh` source line in moved scripts (each script does `source "$(dirname "$0")/lib.sh"` — moving to subdirs requires changing to `source "$(dirname "$0")/../lib.sh"`)

**lib.sh source path fix in moved scripts:**

Current scripts in root use:
```bash
source "$(dirname "$0")/lib.sh"
```

After moving to subdirectory, this becomes:
```bash
source "$(dirname "$0")/../lib.sh"
```

Not all scripts source `lib.sh` — only those that call `print_banner`, `stream_logs`, `sync_exit`, `ensure_dirs`, `is_running`, `container_exists`. Verify which scripts actually source `lib.sh` before updating.

### Pattern 4: Status Table printf Column Widths

Based on the existing dry-run table in migrate.sh (45/10/20/10 column widths):

```bash
# Header
printf "  %-40s  %-8s  %-10s  %-12s  %-8s  %-8s  %s\n" \
  "MODEL" "ECOSYSTEM" "TIER" "SIZE" "LAST USED" "DAYS LEFT" ""

# Row
printf "  %-40s  %-8s  %-10s  %-12s  %-8s  %-8s\n" \
  "${model_short:0:40}" "$ecosystem" "$tier" "$size_fmt" "$last_used_short" "${days_left}d"
```

Model name truncation: `models--org--name` format is typically 20-40 chars; truncate at 40 chars with `${name:0:40}`.

### Anti-Patterns to Avoid

- **Shared op_state.json with migrate/recall during revert:** revert.sh must check for an existing op_state.json from a different operation (e.g., a stuck migrate). Clear it if stale (>4 hours, same logic as migrate.sh lines 68-81) or abort if fresh.
- **Removing cold root directory in revert cleanup:** Only remove `$COLD_PATH/hf/` and `$COLD_PATH/ollama/` subdirs — never `rm -rf $COLD_PATH` itself (it's a mount point the user owns).
- **Skipping TTY check on progress bars when piped:** `rsync --info=progress2` outputs ANSI control codes that pollute log files. Always guard with `[[ -t 1 ]]`.
- **Updating ~/.bash_aliases directly in a task:** The live `~/.bash_aliases` is a user file outside the repo. Tasks should update `example.bash_aliases` (in-repo) and instruct the user to re-copy. The planner should NOT include tasks that modify `~/.bash_aliases` automatically.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Interrupt-safe multi-step operation | Custom state machine | `op_state.json` pattern (already in migrate.sh/recall.sh) | Already battle-tested with stale-state detection |
| Progress during large rsync | Custom byte counter | `rsync --info=progress2` or `pv` (already in Phase 3) | Both tools already validated on DGX Spark |
| Atomic file update | Read-modify-write | `jq ... > tmp && mv tmp file` (already project-wide pattern) | Prevents partial-write corruption |
| JSON manipulation | String concatenation | `jq -cn` with `--arg` / `--argjson` | Already project-wide; avoids quoting bugs |
| Crontab removal | Parse and rewrite crontab manually | `crontab -l | grep -v "modelstore" | crontab -` (same as install_cron inverse) | Exact inverse of the install pattern already in init.sh |

---

## Common Pitfalls

### Pitfall 1: op_state.json Conflict Between revert.sh and migrate.sh/recall.sh

**What goes wrong:** revert.sh starts while a migrate or recall left a fresh op_state.json (e.g., user interrupted a migration 10 minutes ago). revert.sh sees a non-stale state file and either resumes the wrong operation or crashes.

**How to avoid:** At revert.sh startup, read `op_state.json`. If `.op != "revert"`, check age. If age < 4 hours, abort with: "Another operation is in progress (${op}). Run it to completion or wait 4 hours." If age >= 4 hours, clear and proceed.

**Warning signs:** revert.sh skips models that were never reverted, or tries to recall models that weren't migrated.

### Pitfall 2: Moved Scripts Break lib.sh Sourcing

**What goes wrong:** Scripts moved from root to `inference/`, `data/`, etc. still have `source "$(dirname "$0")/lib.sh"` which now looks for `inference/lib.sh` — not found.

**How to avoid:** After each `git mv`, update the source line to `source "$(dirname "$0")/../lib.sh"`. Verify by running `bash -n script.sh` (syntax/source check) after each move.

**Warning signs:** `source: lib.sh: No such file or directory` at runtime.

### Pitfall 3: Revert Leaves Broken Symlinks When Cold Drive Not Mounted

**What goes wrong:** User runs `modelstore revert` without the cold drive mounted. `hf_recall_model` aborts at `check_cold_mounted` guard. After partial revert, some models are hot (recalled) and some are still cold symlinks — inconsistent state.

**How to avoid:** Check cold drive is mounted at the very start of revert.sh, before the preview or any recall. If not mounted, print clear error: "Cold drive not mounted at $COLD_PATH. Mount it first, then re-run."

**Warning signs:** Mix of real directories and dangling symlinks in `$HOT_HF_PATH`.

### Pitfall 4: NVIDIA Sync Status Entry — No Port Means Different Config

**What goes wrong:** NVIDIA Sync custom app entries with a port cause Sync to try to forward that port. `modelstore status` is a CLI command with no port — registering it with a port in the table causes Sync to fail.

**How to avoid:** The README NVIDIA Sync table entry for `modelstore status` must set Port to `—` (none). The command is `bash ~/dgx-toolbox/modelstore.sh status`. Auto-open should be `No`. Document this explicitly.

### Pitfall 5: Revert Preview Exits Non-Zero in --force Mode

**What goes wrong:** `--force` is meant for non-interactive use. If the preview/prompt logic uses `read` without a TTY guard, it hangs waiting for stdin in headless context.

**How to avoid:** The prompt block must be wrapped in `if [[ "$FORCE" != "true" ]] && [[ -t 0 ]]; then`. The `--force` check must come first.

### Pitfall 6: Status Shows Stale Data When Ollama API Is Down

**What goes wrong:** `ollama_list_models` returns 1 if Ollama API is unreachable. If status.sh treats this as a fatal error, the entire status command fails even if HF models are fine.

**How to avoid:** Source and call `ollama_list_models` with `|| true`. If it returns empty, print "Ollama API unavailable — Ollama models not shown" in the dashboard. HF model section should still render.

---

## Code Examples

### status.sh skeleton

```bash
#!/usr/bin/env bash
# modelstore/cmd/status.sh — Model tier status dashboard
# Usage: status.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/config.sh"
source "${SCRIPT_DIR}/../lib/hf_adapter.sh"
source "${SCRIPT_DIR}/../lib/ollama_adapter.sh"

load_config
# Sets: HOT_HF_PATH, HOT_OLLAMA_PATH, COLD_PATH, RETENTION_DAYS, CRON_HOUR

USAGE_FILE="${HOME}/.modelstore/usage.json"
PIDFILE="${HOME}/.modelstore/watcher.pid"

# --- Build model rows ---
# Collect into array for sort-by-size

# Print table header
echo ""
printf "  %-40s  %-8s  %-10s  %-12s  %-10s  %s\n" \
  "MODEL" "ECOSYSTEM" "TIER" "SIZE" "LAST USED" "DAYS LEFT"
printf "  %s\n" "$(printf -- '-%.0s' {1..95})"

# HF models
while IFS=$'\t' read -r model_path size_bytes; do
  [[ -z "$model_path" ]] && continue
  model_short=$(basename "$model_path")
  if [[ -L "$model_path" ]]; then
    target=$(readlink -f "$model_path" 2>/dev/null || true)
    tier=$([[ -n "$target" && -e "$target" ]] && echo "COLD" || echo "BROKEN")
  else
    tier="HOT"
  fi
  last_used=$(jq -r --arg k "$model_path" '.[$k] // "never"' "$USAGE_FILE" 2>/dev/null || echo "never")
  # ... compute days_left, format, print row
done < <(hf_list_models 2>/dev/null | sort -t$'\t' -k2 -rn)

# Ollama models
while IFS=$'\t' read -r model_name size_bytes; do
  # Similar but ecosystem = "Ollama"
  :
done < <(ollama_list_models 2>/dev/null | sort -t$'\t' -k2 -rn || true)

# --- Dashboard summary ---
echo ""
# Drive totals, model counts, watcher, cron, last migration from audit.log
```

### revert.sh op_state append helper

```bash
# Append model path to completed_models array in op_state.json
_append_completed() {
  local model="$1"
  if [[ -f "$OP_STATE_FILE" ]]; then
    jq --arg m "$model" '.completed_models += [$m]' \
      "$OP_STATE_FILE" > "${OP_STATE_FILE}.tmp" \
    && mv "${OP_STATE_FILE}.tmp" "$OP_STATE_FILE"
  fi
}

# Initialize op_state for revert with empty completed_models
_init_revert_state() {
  local total="$1"
  jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson total "$total" \
    '{op:"revert", phase:"recall_hf", started_at:$ts, trigger:"manual",
      completed_models:[], total_models:$total}' \
    > "${OP_STATE_FILE}.tmp"
  mv "${OP_STATE_FILE}.tmp" "$OP_STATE_FILE"
}
```

### Cron uninstall (inverse of install_cron in init.sh)

```bash
# Remove all modelstore crontab entries (exact inverse of install_cron)
remove_cron() {
  if crontab -l 2>/dev/null | grep -q "modelstore"; then
    crontab -l 2>/dev/null | grep -v "modelstore" | crontab -
    ms_log "Cron entries removed"
  else
    ms_log "No modelstore cron entries found"
  fi
}
```

### lib.sh source path in moved scripts

Scripts currently in root:
```bash
source "$(dirname "$0")/lib.sh"
```

After moving to a subdirectory (e.g., `inference/`):
```bash
source "$(dirname "$0")/../lib.sh"
```

### Last migration timestamp from audit.log

```bash
# Read last migration event from audit.log (tail is fine since it's append-only)
AUDIT_LOG="${HOME}/.modelstore/audit.log"
if [[ -f "$AUDIT_LOG" ]]; then
  last_migration=$(grep '"event":"migrate"' "$AUDIT_LOG" 2>/dev/null \
    | tail -1 | jq -r '.timestamp // empty' 2>/dev/null || true)
  echo "Last migration: ${last_migration:-never}"
else
  echo "Last migration: never"
fi
```

---

## State of the Art

| Old Approach | Current Approach | Notes |
|--------------|------------------|-------|
| N/A — new script | `cmd/status.sh` following same source/load_config/printf pattern as migrate.sh | Consistent with Phase 3 |
| N/A — new script | `cmd/revert.sh` with `completed_models[]` array in op_state.json | Extends existing op_state pattern |
| Root-level 20+ script clutter | Category subdirectories: `inference/`, `data/`, `eval/`, `containers/`, `setup/` | No behavior change, only path change |

---

## Open Questions

1. **docker-compose.*.yml script path references**
   - What we know: Neither `docker-compose.inference.yml` nor `docker-compose.data.yml` was read during research — they may or may not reference root scripts.
   - What's unclear: Whether compose files contain `command:` or `entrypoint:` fields that call scripts by path.
   - Recommendation: The plan must include a task that reads both compose files before the reorg task executes, to catch any such references. Based on the file sizes (2.0K and 673B) it is unlikely they reference scripts, but verify.

2. **start-n8n.sh subdirectory placement**
   - What we know: `start-n8n.sh` is a workflow automation script; it could go in `containers/` or stay in root.
   - What's unclear: The CONTEXT.md suggested `inference/`, `data/`, `eval/`, `containers/`, `setup/` — n8n fits containers or could stay in root with `build-toolboxes.sh` and `status.sh`.
   - Recommendation: Claude's discretion — place in `containers/` since it follows the same container launch pattern.

3. **Revert op_state conflict with mid-migrate interruption**
   - What we know: migrate.sh and recall.sh both use `op_state.json` for a single in-progress model. Revert needs a different schema (array of completed models).
   - What's unclear: If a user interrupts a migration and immediately runs revert, what is the right behavior?
   - Recommendation: revert.sh detects `.op != "revert"` in op_state.json + fresh timestamp → abort with "Another operation is in progress. Check migrate/recall state first." This is conservative but safe.

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Inline bash assertions (project-wide pattern — no external framework) |
| Config file | none — scripts are self-contained |
| Quick run command | `bash modelstore/test/test-status.sh` (Wave 0 gap) |
| Full suite command | `bash modelstore/test/run-all.sh` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CLI-01 | `modelstore help` exits 0 and lists subcommands; unknown subcommand exits 1 | smoke | `bash modelstore/test/smoke.sh` | existing (smoke.sh) |
| CLI-03 | `modelstore status` exits 0 with mock config; prints MODEL/ECOSYSTEM/TIER/SIZE headers; prints dashboard | unit | `bash modelstore/test/test-status.sh` | Wave 0 gap |
| CLI-04 | `modelstore revert --force` with mock migrated models: recalls all, removes cron entries, stops watcher | unit | `bash modelstore/test/test-revert.sh` | Wave 0 gap |
| CLI-05 | Interrupt mid-revert (op_state has completed_models=[m1]): re-run skips m1, recalls remaining | unit | `bash modelstore/test/test-revert.sh` | Wave 0 gap |
| CLI-06 | rsync progress2 flag present when stdout is TTY; absent when not TTY | unit | `bash modelstore/test/test-revert.sh` | Wave 0 gap |
| CLI-07 | `--force` skips confirmation prompt; runs without TTY | unit | `bash modelstore/test/test-revert.sh` | Wave 0 gap |
| DOCS-03 | .gitignore contains `modelstore/test/fixtures/tmp*` or similar pattern | manual | grep check in test | manual verification |

### Sampling Rate
- **Per task commit:** `bash modelstore/test/smoke.sh`
- **Per wave merge:** `bash modelstore/test/run-all.sh`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `modelstore/test/test-status.sh` — covers CLI-03 (status output, broken symlink detection, drive totals, watcher/cron display)
- [ ] `modelstore/test/test-revert.sh` — covers CLI-04, CLI-05, CLI-06, CLI-07 (revert loop, op_state idempotency, --force flag, headless mode)
- [ ] Add test-status.sh and test-revert.sh to `modelstore/test/run-all.sh`

---

## Sources

### Primary (HIGH confidence)
- `modelstore/cmd/migrate.sh` (lines 41-81) — `op_state.json` schema, stale-state detection, `_write_op_state` / `_clear_op_state` helpers
- `modelstore/cmd/recall.sh` (lines 39-80) — same op_state helpers; confirms pattern is duplicated per-command (not shared lib)
- `modelstore/cmd/init.sh` (lines 239-263) — `install_cron` function: exact inverse gives `remove_cron` pattern for revert
- `modelstore/hooks/watcher.sh` (line 17) — `PIDFILE="${HOME}/.modelstore/watcher.pid"` location confirmed
- `modelstore/lib/config.sh` — `MODELSTORE_CONFIG="${HOME}/.modelstore/config.json"` and all config keys
- `modelstore/lib/hf_adapter.sh` — `hf_list_models` TSV format, `hf_recall_model` signature
- `modelstore/lib/ollama_adapter.sh` (lines 26-37) — `ollama_list_models` TSV format
- `modelstore/lib/audit.sh` (lines 26-38) — `_audit_rotate_if_needed` shows audit.log location and JSON-line format (for last-migration query)
- `status.sh` (root) — printf table style reference: `printf "  %-20s %-10s %s\n"`
- `example.bash_aliases` — current alias paths; all need updating after reorg
- `README.md` — NVIDIA Sync custom app table format; all script paths needing update

### Secondary (MEDIUM confidence)
- `modelstore/test/run-all.sh` — confirms inline bash assertion pattern (no bats/shunit2); test file naming convention `test-*.sh`

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — zero new dependencies; all tools verified present from prior phases
- Architecture patterns: HIGH — all patterns derived directly from reading existing codebase source
- Pitfalls: HIGH — derived from actual code paths (op_state conflict, lib.sh sourcing, cold drive guard)
- Revert op_state schema: HIGH — designed as natural extension of existing schema pattern
- Subfolder file groupings: MEDIUM — Claude's discretion per CONTEXT.md; groupings are logical but not validated by user

**Research date:** 2026-03-22
**Valid until:** 2026-04-22 (stable — pure bash/jq codebase, no moving external dependencies)
