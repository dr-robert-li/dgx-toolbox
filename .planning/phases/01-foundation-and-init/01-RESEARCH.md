# Phase 1: Foundation and Init - Research

**Researched:** 2026-03-21
**Domain:** Bash config infrastructure, interactive init wizard (gum + read -p fallback), CLI router pattern
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Scripts live in `~/dgx-toolbox/modelstore/` subdirectory with `lib/`, `cmd/`, `hooks/` inside
- CLI entry point at `~/dgx-toolbox/modelstore.sh` — thin router that sources libs, then `exec`'s `cmd/init.sh`, `cmd/status.sh`, etc.
- Separate modelstore libs (`modelstore/lib/common.sh`, `modelstore/lib/config.sh`) — source the existing `lib.sh` plus own libs
- Do NOT extend the existing `lib.sh` directly — modelstore has its own lib namespace
- Check for `gum` (Charm) at startup; if missing, offer to install from Charm apt repo; fall back to `read -p` if user declines
- Filesystem tree preview: show `lsblk` overview first (block devices, sizes, filesystems, mount points), then `ls -la` of top-level mount for the selected drive for confirmation
- Model scan output: formatted table with per-model name + size + last access time, subtotals per ecosystem (HF total, Ollama total), and grand total
- Init validates cold drive filesystem — reject exFAT, require ext4/xfs with clear explanation
- When reinitializing to different drives, prompt user per reinit: "Migrate existing cold models to new cold drive, or recall everything to hot first?"
- After reinit migration complete, auto-cleanup old modelstore directories on old cold drive (after confirming migration success)
- Auto-backup old config as `config.json.bak.<timestamp>` before overwriting
- Config backup retention: 30 days by default (configurable), old backups cleaned up on reinit

### Claude's Discretion
- Config file format (JSON vs key=value) — choose what's easiest to parse in bash
- Exact gum component choices (gum choose, gum input, gum confirm, etc.)
- Table formatting implementation (printf, column, or gum table)
- Error message wording and exit codes

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| INIT-01 | User can run interactive init wizard that shows filesystem tree and selects hot/cold drives and paths | `lsblk` + `gum choose` for drive selection; `gum file` or manual path entry for custom paths |
| INIT-02 | Init creates directory structure on both drives with user confirmation | `gum confirm` → `mkdir -p` pattern; directory structure defined in config schema |
| INIT-03 | User can configure retention period (default 14 days) during init | `gum input --value 14` with integer validation; stored in config |
| INIT-04 | User can configure cron schedule (default 2 AM) during init | `gum input --placeholder "2"` for hour; crontab installed via `crontab -l | ... | crontab -` |
| INIT-05 | Init persists all settings to a config file on disk | JSON via jq (jq 1.7 confirmed on host); `~/.modelstore/config.json` |
| INIT-06 | Init validates cold drive filesystem (rejects exFAT, requires ext4/xfs) | `findmnt -o FSTYPE --target "$COLD_PATH" --noheadings` — confirmed working on this host |
| INIT-07 | Init scans existing models and shows what's where with sizes | `du -sh` + `stat` for HF models--* dirs and Ollama manifests; `printf` table |
| INIT-08 | User can reinitialize to different drives with progress bars for migration and garbage collection on old paths | Config backup → prompt → rsync with `--info=progress2` → cleanup old dirs |
</phase_requirements>

---

## Summary

Phase 1 builds the config layer and init wizard that every subsequent phase depends on. The phase is self-contained: it introduces the `modelstore/` directory tree, the `modelstore.sh` CLI router, shared lib files, and the `cmd/init.sh` wizard that produces `~/.modelstore/config.json`.

The key discretion choice is **JSON over key=value**: `jq` 1.7 is already installed on the DGX host, making JSON strictly better than key=value — jq provides safe reads, writes, and type checking without edge cases around spaces or special characters. The one risk area is `gum` availability; gum is not currently installed on the host, so the init wizard must check at entry and offer a `read -p` fallback path without degrading functionality.

The model-scan step (INIT-07) is a pure bash+coreutils job: walk `$HF_HUB_CACHE/models--*/` for HF models and `~/.ollama/models/manifests/` for Ollama models. `du -sb` for sizes, `stat --format="%Y"` for last-modified timestamps (since atime is unreliable). Format as a `printf` table — `gum table` is available but `printf` is sufficient and has no dependency.

**Primary recommendation:** Use JSON config (jq), gum for interactive UX with `read -p` fallback, `findmnt --output FSTYPE` for filesystem validation, and establish the directory skeleton before writing any cmd/ scripts.

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| bash | 5.2.21 (on host) | Script runtime | Constraint requirement; 5.x gives associative arrays and mapfile |
| jq | 1.7 (confirmed on host) | JSON config read/write | Already installed; handles nested keys, type safety, no shell-injection risk |
| gum | 0.17.0 (Charm apt repo) | Interactive TUI prompts | arm64 binary available; `choose`, `confirm`, `input`, `spin`, `file` |
| findmnt | util-linux 2.39.3 (on host) | Filesystem type detection | `findmnt -o FSTYPE --target PATH` returns exact FS type — more reliable than df |
| lsblk | util-linux 2.39.3 (on host) | Block device overview for drive selection | `lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT` produces exactly what INIT-01 requires |
| rsync | 3.2.7 (on host) | Data movement during reinit (INIT-08) | `--info=progress2` for progress bars; `--remove-source-files` for safe cross-fs move |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| mountpoint | util-linux (on host) | Mount verification | Every script that touches cold paths — `mountpoint -q "$COLD_PATH"` |
| stat | coreutils (on host) | Per-model timestamps for scan | `stat --format="%Y"` for last-modified epoch (reliable; atime is not) |
| du | coreutils (on host) | Model directory sizes for scan | `du -sb` (bytes, not blocks) for accurate space reporting |
| column | util-linux (on host) | Table formatting fallback | If printf alignment is complex; `column -t` for columnar output |
| printf | bash built-in | Table formatting for model scan | `printf "%-40s %8s %12s\n"` — sufficient for all table output |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| JSON (jq) | key=value `source`-able file | key=value is simpler to source but fragile with spaces/special chars in paths; no structured nesting; jq is already present and is the right tool |
| gum | dialog / whiptail | dialog is more universal but produces uglier output and requires ncurses; gum is purpose-built for this use case |
| findmnt | stat -f -c %T | stat -f reports filesystem type but output varies; findmnt is more reliable and machine-parseable |
| printf table | gum table | gum table requires TTY; printf works everywhere |

**Installation:**
```bash
# jq, findmnt, lsblk, mountpoint, stat, du, printf — already on host

# Install gum (offered by init wizard if not present)
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
sudo apt update && sudo apt install gum
```

---

## Architecture Patterns

### Recommended Project Structure
```
dgx-toolbox/
├── modelstore.sh              # CLI entry point (thin router); add alias in example.bash_aliases
└── modelstore/
    ├── lib/
    │   ├── common.sh          # Logging, mount check, space check (sources ../../lib.sh)
    │   └── config.sh          # Read/write ~/.modelstore/config.json; validate drives
    ├── cmd/
    │   └── init.sh            # Interactive wizard: drive select, dir create, config write
    └── hooks/                 # (empty in Phase 1; tracker.sh added in Phase 2)
```

**State directory** (created by init, not in repo):
```
~/.modelstore/
├── config.json                # Single source of truth for all scripts
├── config.json.bak.<timestamp># Auto-backup before each reinit overwrite
└── usage/                     # (Phase 2) per-model timestamp manifest
```

**Cold drive structure** (created by init at `$COLD_PATH`):
```
/media/robert_li/modelstore-1tb/
└── modelstore/
    ├── huggingface/
    │   └── hub/               # Mirrors ~/.cache/huggingface/hub structure
    └── ollama/
        └── models/            # Mirrors ~/.ollama/models structure
```

### Pattern 1: Thin CLI Router with exec

**What:** `modelstore.sh` is a pure router — sources libs, validates the subcommand, then `exec`'s the appropriate `cmd/*.sh`. No business logic lives in the router.

**When to use:** Always. This pattern keeps the router testable in isolation and allows cron to invoke `cmd/*.sh` directly without going through the router.

**Example:**
```bash
#!/usr/bin/env bash
# ~/dgx-toolbox/modelstore.sh — CLI entry point
set -euo pipefail

MODELSTORE_DIR="$(cd "$(dirname "$(readlink -f "$0")")/modelstore" && pwd)"
MODELSTORE_LIB="${MODELSTORE_DIR}/lib"
MODELSTORE_CMD="${MODELSTORE_DIR}/cmd"

# Source shared libs
# shellcheck source=modelstore/lib/common.sh
source "${MODELSTORE_LIB}/common.sh"
# shellcheck source=modelstore/lib/config.sh
source "${MODELSTORE_LIB}/config.sh"

SUBCOMMAND="${1:-help}"
shift 2>/dev/null || true

case "$SUBCOMMAND" in
  init)     exec "${MODELSTORE_CMD}/init.sh" "$@" ;;
  status)   exec "${MODELSTORE_CMD}/status.sh" "$@" ;;
  migrate)  exec "${MODELSTORE_CMD}/migrate.sh" "$@" ;;
  recall)   exec "${MODELSTORE_CMD}/recall.sh" "$@" ;;
  revert)   exec "${MODELSTORE_CMD}/revert.sh" "$@" ;;
  help|--help|-h)
    echo "Usage: modelstore <subcommand>"
    echo "  init     Interactive setup wizard"
    echo "  status   Show models by tier with sizes"
    echo "  migrate  Move stale models hot→cold"
    echo "  recall   Move model cold→hot"
    echo "  revert   Move all models back to hot, remove symlinks"
    exit 0 ;;
  *)
    echo "Unknown subcommand: ${SUBCOMMAND}" >&2
    echo "Run: modelstore help" >&2
    exit 1 ;;
esac
```

### Pattern 2: Gum with read -p Fallback

**What:** At the top of `cmd/init.sh`, detect gum availability. If absent, offer to install; if declined, set a flag that switches all prompts to `read -p` fallbacks. Every prompt is wrapped in a small function that reads the flag.

**When to use:** Any interactive prompt in init.sh and reinit flows. Never in cron, hooks, or headless scripts.

**Example:**
```bash
#!/usr/bin/env bash
# Top of cmd/init.sh

GUM_AVAILABLE=false
if command -v gum &>/dev/null; then
  GUM_AVAILABLE=true
else
  echo "gum (interactive UI) is not installed."
  echo -n "Install now from Charm apt repo? [y/N] "
  read -r _install_gum
  if [[ "${_install_gum,,}" == "y" ]]; then
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key \
      | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
      | sudo tee /etc/apt/sources.list.d/charm.list
    sudo apt-get update -q && sudo apt-get install -y gum
    GUM_AVAILABLE=true
  fi
fi

# Prompt helper: gum or read -p
prompt_input() {
  local label="$1" default="$2" var_name="$3"
  if $GUM_AVAILABLE; then
    read -r "${var_name?}" < <(gum input --prompt "$label " --value "$default")
  else
    echo -n "$label [$default]: "
    read -r "${var_name?}"
    [[ -z "${!var_name}" ]] && printf -v "$var_name" '%s' "$default"
  fi
}

prompt_confirm() {
  local label="$1"
  if $GUM_AVAILABLE; then
    gum confirm "$label"
  else
    echo -n "$label [y/N]: "
    read -r _yn
    [[ "${_yn,,}" == "y" ]]
  fi
}

prompt_choose() {
  # $1 = label, remaining args = choices; echos selection to stdout
  local label="$1"; shift
  if $GUM_AVAILABLE; then
    gum choose --header "$label" "$@"
  else
    echo "$label"
    local i=1
    for opt in "$@"; do printf "  %d) %s\n" "$i" "$opt"; ((i++)); done
    echo -n "Choice [1]: "
    read -r _choice
    _choice="${_choice:-1}"
    local arr=("$@")
    echo "${arr[$(( _choice - 1 ))]}"
  fi
}
```

### Pattern 3: JSON Config via jq

**What:** `~/.modelstore/config.json` is the canonical config file. All scripts read it via `jq -r`. `config.sh` exposes helper functions `config_read KEY` and `config_write KEY VALUE`. Init writes the full config in one `jq -n` call.

**When to use:** Config reads at the top of every cmd/ and lib/ file (via `source config.sh`). Config writes only in `init.sh`.

**Config schema:**
```json
{
  "version": 1,
  "hot_hf_path": "/home/robert_li/.cache/huggingface/hub",
  "hot_ollama_path": "/home/robert_li/.ollama/models",
  "cold_path": "/media/robert_li/modelstore-1tb/modelstore",
  "retention_days": 14,
  "cron_hour": 2,
  "backup_retention_days": 30,
  "created_at": "2026-03-21T10:00:00Z",
  "updated_at": "2026-03-21T10:00:00Z"
}
```

**config.sh helpers:**
```bash
MODELSTORE_CONFIG="${HOME}/.modelstore/config.json"

config_read() {
  # Usage: config_read .hot_hf_path
  local key="$1"
  jq -r "$key" "$MODELSTORE_CONFIG"
}

config_exists() {
  [[ -f "$MODELSTORE_CONFIG" ]]
}

# Called at top of every script that needs config values
load_config() {
  if ! config_exists; then
    echo "modelstore: not initialized. Run: modelstore init" >&2
    exit 1
  fi
  HOT_HF_PATH=$(config_read '.hot_hf_path')
  HOT_OLLAMA_PATH=$(config_read '.hot_ollama_path')
  COLD_PATH=$(config_read '.cold_path')
  RETENTION_DAYS=$(config_read '.retention_days')
  CRON_HOUR=$(config_read '.cron_hour')
}
```

**Writing config (init.sh):**
```bash
write_config() {
  local hot_hf="$1" hot_ollama="$2" cold="$3" retention="$4" cron_hour="$5" backup_days="$6"
  jq -n \
    --arg hf "$hot_hf" \
    --arg ollama "$hot_ollama" \
    --arg cold "$cold" \
    --argjson ret "$retention" \
    --argjson hour "$cron_hour" \
    --argjson bak "$backup_days" \
    '{
      version: 1,
      hot_hf_path: $hf,
      hot_ollama_path: $ollama,
      cold_path: $cold,
      retention_days: $ret,
      cron_hour: $hour,
      backup_retention_days: $bak,
      created_at: (now | todate),
      updated_at: (now | todate)
    }' > "$MODELSTORE_CONFIG"
  chmod 600 "$MODELSTORE_CONFIG"
}
```

### Pattern 4: Filesystem Validation

**What:** Before accepting a cold drive path, check its filesystem type with `findmnt`. exFAT does not support symlinks — reject immediately with a clear message. Accept ext4, xfs, btrfs.

**When to use:** In `init.sh` immediately after the user selects the cold drive path.

**Example:**
```bash
validate_cold_fs() {
  local cold_path="$1"
  local fstype
  fstype=$(findmnt --output FSTYPE --target "$cold_path" --noheadings 2>/dev/null)
  if [[ -z "$fstype" ]]; then
    echo "ERROR: Cannot determine filesystem type for $cold_path" >&2
    echo "Is the drive mounted?" >&2
    exit 1
  fi
  case "$fstype" in
    ext4|xfs|btrfs)
      return 0 ;;
    exfat|vfat|ntfs)
      echo "ERROR: Cold drive filesystem is '$fstype' — symlinks are not supported." >&2
      echo "Modelstore requires ext4, xfs, or btrfs for the cold drive." >&2
      echo "To reformat: sudo mkfs.ext4 /dev/sdX  (WARNING: destroys all data)" >&2
      exit 1 ;;
    *)
      echo "WARNING: Unknown filesystem '$fstype'. Proceed with caution." >&2
      ;;
  esac
}
```

**Verified on DGX host:**
```
# findmnt output on this host:
/media/robert_li/modelstore-1tb  ext4   (VALID — will be accepted)
/media/robert_li/backup-256g     exfat  (INVALID — will be rejected)
```

### Pattern 5: Model Scan Table (INIT-07)

**What:** After init validates drives, scan both HF and Ollama caches on the hot drive. Display a formatted table: model name, tier, size, last-used timestamp. Show subtotals per ecosystem and a grand total.

**When to use:** In `init.sh` after directory structure is confirmed.

**HF scan logic:**
```bash
scan_hf_models() {
  local hf_hub="$1"  # e.g., ~/.cache/huggingface/hub
  local total_bytes=0
  printf "%-50s %10s %12s\n" "MODEL" "SIZE" "LAST USED"
  printf "%-50s %10s %12s\n" "-----" "----" "---------"
  for model_dir in "${hf_hub}"/models--*/; do
    [[ -d "$model_dir" ]] || continue
    local model_name size_bytes last_used
    model_name=$(basename "$model_dir" | sed 's/^models--//' | tr -- '--' '/')
    size_bytes=$(du -sb "$model_dir" 2>/dev/null | cut -f1)
    last_used=$(stat --format="%Y" "$model_dir" 2>/dev/null)
    total_bytes=$(( total_bytes + size_bytes ))
    local size_human last_human
    size_human=$(numfmt --to=iec-i --suffix=B "$size_bytes" 2>/dev/null || echo "${size_bytes}B")
    last_human=$(date -d "@${last_used}" "+%Y-%m-%d" 2>/dev/null || echo "unknown")
    printf "%-50s %10s %12s\n" "$model_name" "$size_human" "$last_human"
  done
  printf "%-50s %10s\n" "HuggingFace TOTAL" "$(numfmt --to=iec-i --suffix=B "$total_bytes")"
}
```

**Ollama scan logic:**
```bash
scan_ollama_models() {
  local manifests_dir="${HOME}/.ollama/models/manifests"
  local total_bytes=0
  [[ -d "$manifests_dir" ]] || return 0
  printf "\n%-50s %10s %12s\n" "MODEL" "SIZE" "LAST USED"
  printf "%-50s %10s %12s\n" "-----" "----" "---------"
  # Walk registry.ollama.ai/library/{name}/{tag}
  while IFS= read -r manifest_file; do
    local model_tag size_bytes last_used
    # Extract model:tag from path
    model_tag=$(echo "$manifest_file" \
      | sed "s|${manifests_dir}/registry.ollama.ai/library/||" \
      | tr '/' ':')
    # Sum blob sizes from manifest
    local blob_total=0
    while IFS= read -r digest; do
      local blob_path="${HOME}/.ollama/models/blobs/${digest}"
      [[ -f "$blob_path" ]] && blob_total=$(( blob_total + $(stat --format="%s" "$blob_path") ))
    done < <(jq -r '.layers[].digest | gsub(":"; "-")' "$manifest_file" 2>/dev/null)
    size_bytes=$blob_total
    total_bytes=$(( total_bytes + size_bytes ))
    last_used=$(stat --format="%Y" "$manifest_file" 2>/dev/null)
    local size_human last_human
    size_human=$(numfmt --to=iec-i --suffix=B "$size_bytes" 2>/dev/null || echo "${size_bytes}B")
    last_human=$(date -d "@${last_used}" "+%Y-%m-%d" 2>/dev/null || echo "unknown")
    printf "%-50s %10s %12s\n" "$model_tag" "$size_human" "$last_human"
  done < <(find "$manifests_dir" -type f 2>/dev/null)
  printf "%-50s %10s\n" "Ollama TOTAL" "$(numfmt --to=iec-i --suffix=B "$total_bytes")"
}
```

### Pattern 6: Config Backup Before Reinit

**What:** On reinit (running `modelstore init` when `~/.modelstore/config.json` already exists), auto-backup the old config, then clean up backups older than `backup_retention_days`.

**When to use:** At the top of `init.sh`, before prompting any questions, if config already exists.

**Example:**
```bash
backup_config_if_exists() {
  if [[ -f "$MODELSTORE_CONFIG" ]]; then
    local backup="${MODELSTORE_CONFIG}.bak.$(date +%Y%m%dT%H%M%S)"
    cp "$MODELSTORE_CONFIG" "$backup"
    chmod 600 "$backup"
    echo "Backed up existing config to: $backup"
    # Clean up old backups beyond retention
    local retention_days
    retention_days=$(jq -r '.backup_retention_days // 30' "$MODELSTORE_CONFIG")
    find "$(dirname "$MODELSTORE_CONFIG")" \
      -name "config.json.bak.*" \
      -mtime "+${retention_days}" \
      -delete 2>/dev/null || true
  fi
}
```

### Pattern 7: Crontab Installation

**What:** Init installs two cron entries: daily migration and daily disk-check. Use the `crontab -l | ... | crontab -` pattern. Guard against duplicate entries.

**When to use:** At the end of `init.sh` after user confirms configuration.

**Example:**
```bash
install_cron() {
  local cron_hour="$1"
  local cron_dir
  cron_dir="$(cd "$(dirname "$(readlink -f "$0")")/../cron" && pwd)"

  local migrate_cron="0 ${cron_hour} * * * ${cron_dir}/migrate_cron.sh"
  local diskcheck_cron="30 ${cron_hour} * * * ${cron_dir}/disk_check_cron.sh"

  # Remove old modelstore cron entries, add new ones
  (crontab -l 2>/dev/null | grep -v "modelstore" || true
   echo "$migrate_cron"
   echo "$diskcheck_cron"
  ) | crontab -
  echo "Cron installed: daily migration + disk check at ${cron_hour}:00 AM"
}
```

### Pattern 8: Sourcing lib.sh from Nested Lib

**What:** `modelstore/lib/common.sh` sources the existing top-level `lib.sh` using a path relative to its own location. This follows the project's established `source "$(dirname "$0")/lib.sh"` pattern, adapted for a subdirectory.

**When to use:** At the top of `modelstore/lib/common.sh` only. Other modelstore libs source `common.sh`.

**Example:**
```bash
# modelstore/lib/common.sh
# shellcheck source=../../lib.sh
_TOOLBOX_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../" && pwd)/lib.sh"
source "$_TOOLBOX_LIB"

# modelstore-specific logging on top of lib.sh's print_banner
ms_log() {
  echo "[modelstore] $*" >&2
}

ms_die() {
  echo "[modelstore] ERROR: $*" >&2
  exit 1
}

# Mount check — used by every script touching cold store
check_cold_mounted() {
  local cold_path="$1"
  mountpoint -q "$cold_path" || ms_die "Cold drive not mounted: $cold_path"
}
```

### Anti-Patterns to Avoid

- **Hardcoded paths in scripts:** Every path comes from config.json. Never hardcode `/media/robert_li/modelstore-1tb`.
- **`test -d` for mount check:** A directory exists even on an unmounted mount point. Use `mountpoint -q "$path"` exclusively.
- **`source`-ing config.sh with side effects:** `config.sh` must be side-effect-free — no echo, no mkdir, no validation that exits on source. Side effects go in `load_config()` which scripts call explicitly.
- **Interactive prompts in common.sh or config.sh:** Only `cmd/init.sh` is interactive. Lib files are always headless-safe.
- **Writing config with shell string concatenation:** Use `jq -n ... > config.json` exclusively to avoid JSON escaping bugs with special characters in paths.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| JSON read/write | awk/sed/grep on config.json | jq (already installed) | jq handles escaping, nesting, and type coercion correctly; hand-rolled JSON parsers break on spaces and quotes in paths |
| Filesystem type detection | Parse `/etc/mtab` or `/proc/mounts` | `findmnt --output FSTYPE --target PATH` | findmnt is the correct tool; mtab parsing breaks with overlay and bind mounts |
| Mount verification | `ls -la "$path"` or `test -d "$path"` | `mountpoint -q "$path"` | ls/test return 0 even when mount point directory exists but drive is not mounted |
| Interactive prompts | Custom ncurses in bash | gum (with read -p fallback) | gum handles cursor, terminal sizing, and escape codes correctly |
| Crontab management | sed on `/var/spool/cron/...` | `crontab -l | ... | crontab -` pattern | Direct crontab file editing requires root and is system-specific |
| Backup filename generation | Hand-coded date strings | `date +%Y%m%dT%H%M%S` in filename | Standard ISO timestamp, sorts correctly alphabetically |

**Key insight:** The two most error-prone DIY areas in this phase are JSON manipulation (use jq) and filesystem type detection (use findmnt). Both tools are already installed on the DGX host with no installation step needed.

---

## Common Pitfalls

### Pitfall 1: exFAT Cold Drive Silently Fails ln -s

**What goes wrong:** User selects the `backup-256g` drive (exFAT) as cold store. `ln -s` fails silently or with a cryptic error on exFAT because that filesystem doesn't support symlinks. The init appears to succeed but migration will fail later.

**Why it happens:** `ln -s` exit code is non-zero on exFAT but `set -e` may not catch it if used in a conditional.

**How to avoid:** Validate filesystem type with `findmnt` immediately after the user selects the cold path, before creating any directories or writing config. Reject exFAT, vfat, and ntfs with a clear error message and reformatting instructions.

**Warning signs:** `ln -s` returns "Operation not supported" — test this directly on the actual `backup-256g` mount.

### Pitfall 2: Reinit on Existing Symlink Destination

**What goes wrong:** User runs `modelstore init` again pointing to a different cold drive. If the new cold path happens to be a symlink (or inside a symlink), `mkdir -p` walks through it, and subsequent `rm -rf` cleanup on the "old path" could follow the symlink into unexpected territory.

**Why it happens:** `rm -rf` doesn't check whether its target is a symlink before recursing.

**How to avoid:** Before any `rm -rf`, explicitly check: `[[ -L "$path" ]] && unlink "$path" || rm -rf "$path"`. Always check `[[ -L "$path" ]]` before treating a path as a real directory.

### Pitfall 3: Config Written Before Directory Exists

**What goes wrong:** `write_config()` writes `~/.modelstore/config.json` before `mkdir -p ~/.modelstore/` is called, causing a "No such file or directory" error.

**Why it happens:** Order of operations not enforced.

**How to avoid:** Always create `~/.modelstore/` before writing the config. In `init.sh`: `mkdir -p "${HOME}/.modelstore/usage"` is the first filesystem operation.

### Pitfall 4: BASH_SOURCE vs $0 in Sourced Libs

**What goes wrong:** `lib/common.sh` uses `dirname "$0"` to locate `lib.sh`. When `common.sh` is sourced (not executed), `$0` refers to the calling script's path, not common.sh's path. The relative path to `lib.sh` is wrong.

**Why it happens:** `$0` is always the top-level script; sourced files must use `${BASH_SOURCE[0]}`.

**How to avoid:** In all lib/ files: `"$(dirname "${BASH_SOURCE[0]}")"` for self-relative paths. In cmd/ scripts: `"$(dirname "$0")"` is fine because they are executed directly.

### Pitfall 5: gum Fails Non-Zero When User Presses Ctrl+C

**What goes wrong:** `gum confirm` returns exit code 1 when user presses Ctrl+C or selects "No". With `set -e`, this immediately exits the script rather than letting the script handle the cancellation gracefully.

**Why it happens:** gum exits non-zero on any cancellation. `set -e` traps this as an error.

**How to avoid:** Wrap all gum calls in conditional expressions or `|| true` for "no" paths:
```bash
if gum confirm "Create directory structure?"; then
  # proceed
else
  echo "Cancelled." ; exit 0
fi
```
Never use `gum confirm || exit 1` — the `|| exit 1` is redundant and the plain `if` pattern is clearer.

### Pitfall 6: numfmt Not Available (Unlikely but Worth Checking)

**What goes wrong:** `numfmt --to=iec-i` is used to format byte counts as "4.2GiB". numfmt is part of coreutils 8.21+ but may not be available in minimal environments.

**Why it happens:** numfmt is a coreutils add-on, not universally installed.

**How to avoid:** `numfmt` is available on Ubuntu 22.04+ (which DGX Spark runs). Confidence is HIGH for this host. If it fails: `awk 'BEGIN{printf "%.1fGiB\n", '"$bytes"'/1073741824}'` as fallback.

### Pitfall 7: Ollama Manifest jq Parsing Wrong Blob Digest Field

**What goes wrong:** The Ollama manifest JSON uses `digest` fields within `layers[]`. A naive `jq '.digest'` on the manifest grabs the wrong field (the manifest's own digest, not the layer digests). The blob path calculation is wrong.

**Why it happens:** The manifest has a top-level `config.digest` and per-layer `layers[].digest`. The blob files are named after the layer digests.

**How to avoid:** Use `jq -r '.layers[].digest'` (not `.digest`) to extract blob digests from an Ollama manifest. The blob filename replaces `:` with `-`: `sha256:abc123` → `sha256-abc123`.

---

## Code Examples

### Drive Selection Flow (INIT-01)

```bash
# Source: ARCHITECTURE.md pattern + lsblk verified on DGX host
select_cold_drive() {
  echo ""
  echo "Available drives:"
  lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT | grep -v "loop\|squash"
  echo ""

  if $GUM_AVAILABLE; then
    # Build choice list from mounted drives
    mapfile -t MOUNTS < <(findmnt -o TARGET,FSTYPE,SIZE --real --noheadings \
      | awk '{print $1"  ("$2", "$3")"}')
    COLD_MOUNT=$(gum choose --header "Select cold drive mount point:" "${MOUNTS[@]}")
    COLD_MOUNT="${COLD_MOUNT%%  (*}"  # strip trailing annotation
  else
    echo -n "Enter cold drive mount point (e.g. /media/robert_li/modelstore-1tb): "
    read -r COLD_MOUNT
  fi

  validate_cold_fs "$COLD_MOUNT"
  COLD_PATH="${COLD_MOUNT}/modelstore"
}
```

### Config Read in a Downstream Script

```bash
# Source: config.sh pattern — used by all Phase 2+ scripts
# At top of cmd/migrate.sh (Phase 3):
MODELSTORE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${MODELSTORE_LIB}/config.sh"

load_config   # exits with message if config not found
check_cold_mounted "$COLD_PATH"  # from common.sh
```

### Reinit Detection and Drive Reconfiguration

```bash
# In cmd/init.sh — handles INIT-08
handle_reinit() {
  local old_cold
  old_cold=$(config_read '.cold_path')
  echo "Existing config found. Cold store: ${old_cold}"
  echo ""

  local choice
  choice=$(prompt_choose "Reinit action:" \
    "Migrate existing cold models to new cold drive" \
    "Recall everything to hot first, then configure new cold drive" \
    "Cancel")

  case "$choice" in
    "Migrate existing cold models"*)
      echo "Will rsync cold store to new location after configuration."
      REINIT_ACTION="migrate" ;;
    "Recall everything"*)
      echo "Will recall all cold models before reconfiguring."
      REINIT_ACTION="recall_first" ;;
    "Cancel")
      exit 0 ;;
  esac
}
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| key=value config sourced with `source config` | JSON config read with jq | jq became ubiquitous (~2017+) | Safer path handling, supports nesting, no eval security risk |
| `dialog`/`whiptail` for TUI | `gum` (charmbracelet) | 2022+ | Better aesthetics, simpler API, no ncurses dependency |
| `test -d` for mount check | `mountpoint -q` | Always correct; convention solidified ~2015 | Prevents false positives on unmounted mount point directories |
| `stat -f -c %T` for filesystem type | `findmnt --output FSTYPE` | `findmnt` preferred since util-linux 2.20 | More reliable across overlay/bind/network mounts |
| `du -sh` for size estimation | `du -sb` (bytes) + `numfmt` | Best practice clarified as storage systems grew | Avoids block-size-dependent estimates; accurate cross-filesystem |

**Deprecated/outdated:**
- `dialog`: Works but aesthetically dated; gum produces cleaner TUI with less code
- `read -p` as primary: Remains valid as gum fallback but not preferred when gum is available
- `atime` for model last-used: Unreliable under `relatime` and on symlinks; Phase 2 introduces explicit manifest

---

## Open Questions

1. **Ollama manifest JSON schema**
   - What we know: Blob digests are in `.layers[].digest`; format is `sha256:hex`
   - What's unclear: Whether newer Ollama versions (post-0.6) change the manifest schema
   - Recommendation: Before implementing Ollama scan in init.sh, read one actual manifest on the DGX: `cat ~/.ollama/models/manifests/registry.ollama.ai/library/*/latest 2>/dev/null | jq .`

2. **gum not installed on host**
   - What we know: `command -v gum` returns nothing on the DGX host today
   - What's unclear: Whether the user wants to install it now or rely on the fallback
   - Recommendation: Init wizard must work fully without gum; test the `read -p` path end-to-end before adding gum polish

3. **Hot HF path variability**
   - What we know: Default is `~/.cache/huggingface/hub`; configurable via `HF_HOME` env var
   - What's unclear: Whether the user has set a custom `HF_HOME`
   - Recommendation: In init.sh, default the hot HF path to `${HF_HOME:-${HOME}/.cache/huggingface}/hub` and display it for user confirmation

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | bats-core (bash automated testing system) |
| Config file | none — see Wave 0 |
| Quick run command | `bats modelstore/test/` |
| Full suite command | `bats modelstore/test/ --timing` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| INIT-01 | lsblk output shown; drive selected | manual-only | n/a — requires TTY + physical drives | n/a |
| INIT-02 | Directories created on both drives | integration | `bats modelstore/test/test_init.bats` | ❌ Wave 0 |
| INIT-03 | Retention days stored in config | unit | `bats modelstore/test/test_config.bats` | ❌ Wave 0 |
| INIT-04 | Cron hour stored; crontab entry created | integration | `bats modelstore/test/test_init.bats` | ❌ Wave 0 |
| INIT-05 | config.json written; parseable by jq | unit | `bats modelstore/test/test_config.bats` | ❌ Wave 0 |
| INIT-06 | exFAT rejected; ext4 accepted | unit | `bats modelstore/test/test_config.bats` | ❌ Wave 0 |
| INIT-07 | Model scan produces table output | integration | `bats modelstore/test/test_init.bats` | ❌ Wave 0 |
| INIT-08 | Reinit backs up config; prompts for reinit action | integration | `bats modelstore/test/test_init.bats` | ❌ Wave 0 |

**Manual-only justification (INIT-01):** Drive selection requires an interactive TTY and physical drives with different filesystem types. The filesystem validation sub-step (INIT-06) is unit-testable via a stub function.

### Sampling Rate
- **Per task commit:** `bats modelstore/test/test_config.bats -x`
- **Per wave merge:** `bats modelstore/test/ --timing`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `modelstore/test/test_config.bats` — covers INIT-03, INIT-05, INIT-06
- [ ] `modelstore/test/test_init.bats` — covers INIT-02, INIT-04, INIT-07, INIT-08
- [ ] Framework install: `sudo apt install bats` — if not present (`command -v bats`)
- [ ] `modelstore/test/fixtures/` — test fixtures (mock config.json, mock drive paths using temp dirs)

---

## Sources

### Primary (HIGH confidence)
- `findmnt -o TARGET,FSTYPE,SIZE -t ext4,xfs,btrfs,exfat` — verified directly on DGX host; confirmed `modelstore-1tb` is ext4, `backup-256g` is exfat
- `lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT` — verified on DGX host
- `jq --version` on DGX host → jq 1.7 (already installed, no installation step needed)
- `lib.sh` — read directly; `get_ip()`, `ensure_dirs()`, `print_banner()` available for reuse
- `setup-litellm-config.sh` — pattern reference for interactive config generation with service detection
- `status.sh` — pattern reference for `printf "%-20s %-10s %s\n"` table formatting
- [charmbracelet/gum releases v0.17.0](https://github.com/charmbracelet/gum/releases/tag/v0.17.0) — arm64 apt install confirmed; HIGH confidence
- [gum interactive prompts guide (2025)](https://www.kamilachyla.com/en/posts/2025-03-30_gum_for_better_shell_scripts/) — MEDIUM confidence
- ARCHITECTURE.md — init flow, config schema, dispatcher pattern (HIGH confidence, project-internal)
- STACK.md — gum, findmnt, jq stack recommendations (HIGH confidence, project-internal)
- PITFALLS.md — exFAT rejection, symlink loop on reinit, BASH_SOURCE in sourced libs (HIGH confidence, project-internal)
- CONVENTIONS.md — `set -euo pipefail`, UPPERCASE vars, kebab-case files, `printf` tables (HIGH confidence, project-internal)

### Secondary (MEDIUM confidence)
- [gum file picker issues on GitHub](https://github.com/charmbracelet/gum/issues/887) — confirms `gum file --directory` exists but has edge cases in virtual filesystems; use `gum choose` from a list of mounts instead for drive selection
- WebSearch: jq vs key=value for bash config — consensus: jq is strictly better when available; key=value only acceptable when jq is unavailable

### Tertiary (LOW confidence)
- Ollama manifest JSON schema `.layers[].digest` path — derived from STACK.md/ARCHITECTURE.md cross-references; should be verified by reading an actual manifest on the DGX before implementing Ollama scan

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — jq, findmnt, lsblk, gum all verified or confirmed on DGX host
- Architecture: HIGH — router, config.sh, init.sh patterns drawn from project's existing code style
- Pitfalls: HIGH — most drawn from PITFALLS.md which was previously researched with verification
- Ollama scan: MEDIUM — manifest field paths not yet verified on actual DGX instance

**Research date:** 2026-03-21
**Valid until:** 2026-06-21 (stable tooling; gum API may change on major version bump)
