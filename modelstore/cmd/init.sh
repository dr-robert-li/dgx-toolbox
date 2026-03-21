#!/usr/bin/env bash
# modelstore init — Interactive setup wizard
# Guides the user through drive selection, config entry, model scanning,
# and crontab installation. Uses gum for rich TUI with read -p fallback.
set -euo pipefail

MODELSTORE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${MODELSTORE_LIB}/common.sh"
source "${MODELSTORE_LIB}/config.sh"

# ---------------------------------------------------------------------------
# Section 1: Prompt helper functions (gum / read -p fallback)
# ---------------------------------------------------------------------------

GUM_AVAILABLE=false

_detect_or_install_gum() {
  if command -v gum &>/dev/null; then
    GUM_AVAILABLE=true
    return
  fi
  echo "gum (interactive UI) is not installed."
  echo -n "Install now from Charm apt repo? [y/N] "
  read -r _install_gum || _install_gum=""
  if [[ "${_install_gum,,}" == "y" ]]; then
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key \
      | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
      | sudo tee /etc/apt/sources.list.d/charm.list
    sudo apt-get update -q && sudo apt-get install -y gum
    GUM_AVAILABLE=true
  fi
}

# prompt_input "$label" "$default" var_name
# Sets the named variable to the user's input (or default if empty).
prompt_input() {
  local label="$1" default="$2" var_name="$3"
  if $GUM_AVAILABLE; then
    read -r "${var_name?}" < <(gum input --prompt "$label " --value "$default")
  else
    echo -n "$label [$default]: "
    read -r "${var_name?}" || printf -v "$var_name" '%s' "$default"
    [[ -z "${!var_name}" ]] && printf -v "$var_name" '%s' "$default"
  fi
}

# prompt_confirm "$label"
# Returns 0 if user confirms, non-zero if declined.
prompt_confirm() {
  local label="$1"
  if $GUM_AVAILABLE; then
    if gum confirm "$label"; then
      return 0
    else
      return 1
    fi
  else
    echo -n "$label [y/N]: "
    read -r _yn || _yn=""
    [[ "${_yn,,}" == "y" ]]
  fi
}

# prompt_choose "$label" choice1 choice2 ...
# Echos the selected choice to stdout.
prompt_choose() {
  local label="$1"; shift
  if $GUM_AVAILABLE; then
    gum choose --header "$label" "$@"
  else
    echo "$label"
    local i=1
    for opt in "$@"; do printf "  %d) %s\n" "$i" "$opt"; i=$((i + 1)); done
    echo -n "Choice [1]: "
    read -r _choice || _choice="1"
    _choice="${_choice:-1}"
    local arr=("$@")
    echo "${arr[$(( _choice - 1 ))]}"
  fi
}

# ---------------------------------------------------------------------------
# Section 6: Model scan functions
# ---------------------------------------------------------------------------

# scan_hf_models [hf_hub_path]
# Prints a formatted table of HuggingFace models with sizes and last-used dates.
scan_hf_models() {
  local hf_hub="${1:-}"
  [[ -z "$hf_hub" ]] && hf_hub="${HOT_HF_PATH:-}"
  if [[ -z "$hf_hub" ]] || [[ ! -d "$hf_hub" ]]; then
    echo "  (no HuggingFace hub directory found at ${hf_hub:-unset})"
    return 0
  fi
  local total_bytes=0
  printf "%-50s %10s %12s\n" "MODEL" "SIZE" "LAST USED"
  printf "%-50s %10s %12s\n" "-----" "----" "---------"
  for model_dir in "${hf_hub}"/models--*/; do
    [[ -d "$model_dir" ]] || continue
    local model_name size_bytes last_used size_human last_human
    model_name=$(basename "$model_dir" | sed 's/^models--//' | sed 's/--/\//g')
    size_bytes=$(du -sb "$model_dir" 2>/dev/null | cut -f1)
    last_used=$(stat --format="%Y" "$model_dir" 2>/dev/null)
    total_bytes=$(( total_bytes + size_bytes ))
    size_human=$(numfmt --to=iec-i --suffix=B "$size_bytes" 2>/dev/null \
      || awk "BEGIN{printf \"%.1fGiB\n\", ${size_bytes}/1073741824}")
    last_human=$(date -d "@${last_used}" "+%Y-%m-%d" 2>/dev/null || echo "unknown")
    printf "%-50s %10s %12s\n" "$model_name" "$size_human" "$last_human"
  done
  local total_human
  total_human=$(numfmt --to=iec-i --suffix=B "$total_bytes" 2>/dev/null \
    || awk "BEGIN{printf \"%.1fGiB\n\", ${total_bytes}/1073741824}")
  printf "%-50s %10s\n" "HuggingFace TOTAL" "$total_human"
}

# scan_ollama_models
# Prints a formatted table of Ollama models with sizes and last-used dates.
scan_ollama_models() {
  local ollama_path="${HOT_OLLAMA_PATH:-${HOME}/.ollama/models}"
  local manifests_dir="${ollama_path}/manifests"
  if [[ ! -d "$manifests_dir" ]]; then
    echo "  (no Ollama manifests directory found at ${manifests_dir})"
    return 0
  fi
  local total_bytes=0
  printf "\n%-50s %10s %12s\n" "MODEL" "SIZE" "LAST USED"
  printf "%-50s %10s %12s\n" "-----" "----" "---------"
  while IFS= read -r manifest_file; do
    local model_tag size_bytes last_used size_human last_human blob_total
    model_tag=$(echo "$manifest_file" \
      | sed "s|${manifests_dir}/registry.ollama.ai/library/||" \
      | tr '/' ':')
    blob_total=0
    while IFS= read -r digest; do
      local blob_path="${ollama_path}/blobs/${digest}"
      [[ -f "$blob_path" ]] && blob_total=$(( blob_total + $(stat --format="%s" "$blob_path") ))
    done < <(jq -r '.layers[].digest | gsub(":"; "-")' "$manifest_file" 2>/dev/null)
    size_bytes=$blob_total
    total_bytes=$(( total_bytes + size_bytes ))
    last_used=$(stat --format="%Y" "$manifest_file" 2>/dev/null)
    size_human=$(numfmt --to=iec-i --suffix=B "$size_bytes" 2>/dev/null \
      || awk "BEGIN{printf \"%.1fGiB\n\", ${size_bytes}/1073741824}")
    last_human=$(date -d "@${last_used}" "+%Y-%m-%d" 2>/dev/null || echo "unknown")
    printf "%-50s %10s %12s\n" "$model_tag" "$size_human" "$last_human"
  done < <(find "$manifests_dir" -type f 2>/dev/null)
  local total_human
  total_human=$(numfmt --to=iec-i --suffix=B "$total_bytes" 2>/dev/null \
    || awk "BEGIN{printf \"%.1fGiB\n\", ${total_bytes}/1073741824}")
  printf "%-50s %10s\n" "Ollama TOTAL" "$total_human"
}

# show_existing_models
# Prints all models currently on hot storage with sizes.
show_existing_models() {
  echo ""
  echo "Current models on hot storage:"
  echo "================================"
  echo "--- HuggingFace Models ---"
  scan_hf_models "${HOT_HF_PATH:-}"
  echo ""
  echo "--- Ollama Models ---"
  scan_ollama_models
  echo ""
  echo "================================"
}

# ---------------------------------------------------------------------------
# Section 8: Crontab installation
# ---------------------------------------------------------------------------

install_cron() {
  local cron_hour="$1"
  local cron_dir
  cron_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../cron" && pwd)"

  local migrate_cron="0 ${cron_hour} * * * ${cron_dir}/migrate_cron.sh"
  local diskcheck_cron="30 ${cron_hour} * * * ${cron_dir}/disk_check_cron.sh"

  # Remove old modelstore cron entries, append new ones
  (crontab -l 2>/dev/null | grep -v "modelstore" || true
   echo "$migrate_cron"
   echo "$diskcheck_cron"
  ) | crontab -
  ms_log "Cron installed: daily migration + disk check at ${cron_hour}:00"
}

# ---------------------------------------------------------------------------
# Main wizard flow (only runs when executed directly, not when sourced)
# ---------------------------------------------------------------------------

main() {
  # -- Section 1: Detect or install gum --
  _detect_or_install_gum

  # -- Section 2: Reinit detection --
  local REINIT_ACTION=""
  local old_cold=""

  if config_exists; then
    backup_config_if_exists
    old_cold=$(config_read '.cold_path')
    echo ""
    echo "Existing config found. Cold store: ${old_cold}"

    # Show existing models before asking what to do
    HOT_HF_PATH=$(config_read '.hot_hf_path')
    HOT_OLLAMA_PATH=$(config_read '.hot_ollama_path')
    show_existing_models

    local reinit_choice
    reinit_choice=$(prompt_choose "Reinit action:" \
      "Migrate existing cold models to new cold drive" \
      "Recall everything to hot first, then configure new cold drive" \
      "Cancel")

    case "$reinit_choice" in
      "Migrate existing cold models"*)
        REINIT_ACTION="migrate" ;;
      "Recall everything"*)
        REINIT_ACTION="recall_first" ;;
      "Cancel")
        echo "Cancelled."
        exit 0 ;;
    esac
  fi

  # -- Section 3: Hot path detection --
  local HOT_HF_DEFAULT="${HF_HOME:-${HOME}/.cache/huggingface}/hub"
  local HOT_OLLAMA_DEFAULT="${HOME}/.ollama/models"

  echo ""
  echo "Hot storage paths:"
  echo "  HuggingFace hub: ${HOT_HF_DEFAULT}"
  echo "  Ollama models:   ${HOT_OLLAMA_DEFAULT}"
  echo ""

  local HOT_HF_PATH HOT_OLLAMA_PATH
  prompt_input "HuggingFace hub path" "$HOT_HF_DEFAULT" HOT_HF_PATH
  prompt_input "Ollama models path" "$HOT_OLLAMA_DEFAULT" HOT_OLLAMA_PATH

  # -- Section 4: Cold drive selection --
  echo ""
  echo "Available drives:"
  lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT | grep -v "loop\|squash"
  echo ""

  local COLD_MOUNT=""
  if $GUM_AVAILABLE; then
    local -a MOUNTS
    mapfile -t MOUNTS < <(findmnt -o TARGET,FSTYPE,SIZE --real --noheadings \
      | awk '{print $1"  ("$2", "$3")"}')
    local COLD_MOUNT_RAW
    COLD_MOUNT_RAW=$(gum choose --header "Select cold drive mount point:" "${MOUNTS[@]}")
    COLD_MOUNT="${COLD_MOUNT_RAW%%  (*}"
  else
    prompt_input "Enter cold drive mount point" "/media/${USER}" COLD_MOUNT
  fi

  # Validate filesystem type — prints error and returns 1 if exFAT/vfat/ntfs
  if ! validate_cold_fs "$COLD_MOUNT"; then
    ms_die "Cold drive filesystem not supported. Please use ext4, xfs, or btrfs."
  fi

  local COLD_PATH="${COLD_MOUNT}/modelstore"

  echo ""
  echo "Cold drive contents:"
  ls -la "$COLD_MOUNT" 2>/dev/null || echo "  (empty or not yet mounted)"
  echo ""
  echo "Cold store will be created at: ${COLD_PATH}"

  if ! prompt_confirm "Use ${COLD_PATH} as cold store?"; then
    echo "Cancelled."
    exit 0
  fi

  # -- Section 5: Retention and cron config --
  echo ""
  local RETENTION_DAYS CRON_HOUR BACKUP_RETENTION_DAYS
  prompt_input "Retention period (days)" "14" RETENTION_DAYS
  if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    ms_die "Retention must be a positive integer, got: ${RETENTION_DAYS}"
  fi

  prompt_input "Cron hour (0-23, daily migration)" "2" CRON_HOUR
  if ! [[ "$CRON_HOUR" =~ ^[0-9]+$ ]] || (( CRON_HOUR < 0 || CRON_HOUR > 23 )); then
    ms_die "Cron hour must be 0-23, got: ${CRON_HOUR}"
  fi

  prompt_input "Config backup retention (days)" "30" BACKUP_RETENTION_DAYS
  if ! [[ "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    ms_die "Backup retention must be a positive integer, got: ${BACKUP_RETENTION_DAYS}"
  fi

  # -- Scan models after paths confirmed --
  show_existing_models

  # -- Section 7: Confirmation and directory creation --
  echo ""
  echo "Configuration summary:"
  echo "  HuggingFace hub:  ${HOT_HF_PATH}"
  echo "  Ollama models:    ${HOT_OLLAMA_PATH}"
  echo "  Cold store:       ${COLD_PATH}"
  echo "  Retention:        ${RETENTION_DAYS} days"
  echo "  Cron hour:        ${CRON_HOUR}:00 daily"
  echo "  Backup retention: ${BACKUP_RETENTION_DAYS} days"
  echo ""

  if ! prompt_confirm "Create directory structure and save config?"; then
    echo "Cancelled."
    exit 0
  fi

  # Create state directory first (before writing config!)
  mkdir -p "${HOME}/.modelstore/usage"

  # Create cold drive directory structure
  mkdir -p "${COLD_PATH}/huggingface/hub"
  mkdir -p "${COLD_PATH}/ollama/models"
  ms_log "Created cold drive directories at ${COLD_PATH}"

  # Write config via lib helper
  write_config "$HOT_HF_PATH" "$HOT_OLLAMA_PATH" "$COLD_PATH" \
    "$RETENTION_DAYS" "$CRON_HOUR" "$BACKUP_RETENTION_DAYS"
  ms_log "Config saved to ${MODELSTORE_CONFIG}"

  # -- Section 8: Crontab installation --
  install_cron "$CRON_HOUR"

  # -- Section 9: Reinit actions --
  if [[ -n "$REINIT_ACTION" ]]; then
    case "$REINIT_ACTION" in
      migrate)
        echo ""
        echo "Migrating cold models from ${old_cold} to ${COLD_PATH}..."
        rsync -av --info=progress2 "${old_cold}/" "${COLD_PATH}/"
        echo ""
        if prompt_confirm "Remove old cold store at ${old_cold}?"; then
          if [[ -L "$old_cold" ]]; then
            unlink "$old_cold"
          else
            rm -rf "${old_cold}"
          fi
          ms_log "Removed old cold store: ${old_cold}"
        fi
        ;;
      recall_first)
        echo ""
        echo "Note: Recall is a Phase 3 feature."
        echo "After Phase 3 is complete, run: modelstore recall --all"
        echo "Then run modelstore init again to reconfigure the cold drive."
        ;;
    esac
  fi

  echo ""
  echo "Init complete. Config saved to ${MODELSTORE_CONFIG}"
}

# Only run main when executed directly (not when sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
