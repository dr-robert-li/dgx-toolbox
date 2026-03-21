#!/usr/bin/env bash
# modelstore/lib/hf_adapter.sh — HuggingFace storage adapter
# Provides 5 functions for listing, sizing, migrating, and recalling HF models.
# Sourced by migrate.sh and recall.sh — caller controls error handling, no side effects on source.

_MS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${_MS_LIB}/common.sh"
# shellcheck source=./config.sh
source "${_MS_LIB}/config.sh"

# ---------------------------------------------------------------------------
# hf_list_models
# Prints TSV: model_path<TAB>size_bytes — one line per HF model.
# model_path is the absolute path to the models--org--name/ directory.
# ---------------------------------------------------------------------------
hf_list_models() {
  load_config  # sets HOT_HF_PATH

  # Primary: Python huggingface_hub API (authoritative)
  if python3 -c "from huggingface_hub import scan_cache_dir" &>/dev/null; then
    python3 -c "
from huggingface_hub import scan_cache_dir
info = scan_cache_dir()
for repo in info.repos:
    path = str(repo.repo_path)
    print(f'{path}\t{repo.size_on_disk}')
" 2>/dev/null
    return 0
  fi

  # Fallback: directory walk using du -sb
  for model_dir in "${HOT_HF_PATH}"/models--*/; do
    [[ -d "$model_dir" ]] || continue
    local size
    size=$(du -sb "$model_dir" 2>/dev/null | cut -f1)
    printf '%s\t%s\n' "${model_dir%/}" "$size"
  done
}

# ---------------------------------------------------------------------------
# hf_get_model_size <model_id>
# Prints size in bytes to stdout. model_id is the absolute path to models--*/ dir.
# ---------------------------------------------------------------------------
hf_get_model_size() {
  local model_id="$1"
  du -sb "$model_id" 2>/dev/null | cut -f1
}

# ---------------------------------------------------------------------------
# hf_get_model_path <model_id>
# Prints the absolute path to stdout. model_id IS the path; echoes for interface
# consistency with Ollama adapter.
# ---------------------------------------------------------------------------
hf_get_model_path() {
  local model_id="$1"
  echo "$model_id"
}

# ---------------------------------------------------------------------------
# hf_migrate_model <model_id> <cold_base>
# Moves HF model directory to cold storage and creates an atomic symlink in its place.
# Guards: cold mounted, sufficient space, not already migrated.
# Returns 0 on success, 1 on insufficient space, exits via ms_die on fatal errors.
# ---------------------------------------------------------------------------
hf_migrate_model() {
  local model_id="$1"
  local cold_base="$2"

  # Skip if already a symlink (already migrated — check before mount/space guards)
  if [[ -L "$model_id" ]]; then
    ms_log "Already migrated: $model_id"
    return 0
  fi

  # Guard 1: cold drive must be mounted (ms_die on failure)
  check_cold_mounted "$cold_base"

  # Guard 2: sufficient space on cold drive
  local size
  size=$(hf_get_model_size "$model_id")
  if ! check_space "$cold_base" "$size"; then
    return 1
  fi

  # Compute cold target path: <cold_base>/hf/<models--org--name>
  local dirname
  dirname=$(basename "$model_id")
  local cold_target="${cold_base}/hf/${dirname}"

  # Create cold subdirectory
  mkdir -p "${cold_base}/hf"

  # Move files using rsync with --remove-source-files (safe cross-filesystem move)
  rsync -a --remove-source-files "$model_id/" "$cold_target/"

  # Remove empty source directories left by rsync
  find "$model_id" -type d -empty -delete 2>/dev/null || true
  rmdir "$model_id" 2>/dev/null || true

  # Atomic symlink swap: create new symlink then mv -T (atomic rename)
  ln -s "$cold_target" "${model_id}.new"
  mv -T "${model_id}.new" "$model_id"

  ms_log "Migrated HF model: $model_id -> $cold_target"
}

# ---------------------------------------------------------------------------
# hf_recall_model <model_id> <hot_base>
# Moves HF model back from cold storage to hot, replacing the symlink with the
# actual directory.
# Returns 0 on success, 1 on insufficient space, skips if not a symlink.
# ---------------------------------------------------------------------------
hf_recall_model() {
  local model_id="$1"
  local hot_base="$2"

  # Skip if not a symlink (not on cold store)
  if [[ ! -L "$model_id" ]]; then
    ms_log "Not a symlink, skip recall: $model_id"
    return 0
  fi

  # Resolve actual cold target
  local cold_target
  cold_target=$(readlink -f "$model_id")

  # Guard: cold drive must be mounted (cold_base is parent of hf/ subdir)
  check_cold_mounted "$(dirname "$(dirname "$cold_target")")"

  # Guard: sufficient space on hot drive
  local size
  size=$(du -sb "$cold_target" | cut -f1)
  if ! check_space "$(dirname "$model_id")" "$size"; then
    return 1
  fi

  # Remove symlink
  rm "$model_id"

  # Move files back using rsync
  rsync -a --remove-source-files "$cold_target/" "$model_id/"

  # Clean up empty cold directories
  find "$cold_target" -type d -empty -delete 2>/dev/null || true
  rmdir "$cold_target" 2>/dev/null || true

  ms_log "Recalled HF model: $cold_target -> $model_id"
}
