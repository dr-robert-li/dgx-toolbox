#!/usr/bin/env bash
# modelstore/lib/ollama_adapter.sh — Ollama API storage adapter
# Provides 6 functions for listing, sizing, migrating, and recalling Ollama models.
# All operations are API-only: no elevated privileges, no direct filesystem access.
# Sourced by migrate.sh and recall.sh — caller controls error handling, no side effects on source.

_MS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${_MS_LIB}/common.sh"
# shellcheck source=./config.sh
source "${_MS_LIB}/config.sh"

# ---------------------------------------------------------------------------
# ollama_check_server
# Returns 0 if Ollama server is running, 1 if not.
# Checks systemctl first (authoritative), then curl as fallback.
# ---------------------------------------------------------------------------
ollama_check_server() {
  systemctl is-active --quiet ollama 2>/dev/null && return 0
  curl -sf http://localhost:11434/api/tags >/dev/null 2>&1 && return 0
  return 1
}

# ---------------------------------------------------------------------------
# ollama_list_models
# Prints TSV: model_name<TAB>size_bytes — one line per Ollama model.
# Uses /api/tags endpoint. Returns 1 if Ollama API unreachable.
# ---------------------------------------------------------------------------
ollama_list_models() {
  local api_response
  api_response=$(curl -sf http://localhost:11434/api/tags 2>/dev/null)
  if [[ -z "$api_response" ]]; then
    ms_log "WARNING: Cannot reach Ollama API"
    return 1
  fi
  echo "$api_response" | jq -r '.models[] | [.name, (.size|tostring)] | @tsv'
}

# ---------------------------------------------------------------------------
# ollama_get_model_size <model_name>
# Prints size in bytes to stdout by querying /api/tags.
# ---------------------------------------------------------------------------
ollama_get_model_size() {
  local model_name="$1"
  curl -sf http://localhost:11434/api/tags 2>/dev/null \
    | jq -r --arg name "$model_name" '.models[] | select(.name == $name) | .size'
}

# ---------------------------------------------------------------------------
# ollama_get_model_path <model_name>
# Prints the model name (Ollama is API-only — no filesystem paths exposed).
# Exists for interface consistency with hf_adapter.sh.
# ---------------------------------------------------------------------------
ollama_get_model_path() {
  local model_name="$1"
  echo "$model_name"
}

# ---------------------------------------------------------------------------
# _ollama_manifest_blobs <manifest_file>
# Parse blob digests from an Ollama manifest JSON file.
# Outputs one digest per line in sha256-<hex> format (as used in blobs/ dir).
# ---------------------------------------------------------------------------
_ollama_manifest_blobs() {
  local manifest_file="$1"
  jq -r '([.layers[].digest] + [.config.digest]) | .[]' "$manifest_file" 2>/dev/null \
    | sed 's|sha256:|sha256-|'
}

# ---------------------------------------------------------------------------
# _ollama_blob_hot_refs <digest>
# Count how many hot manifests reference the given blob digest.
# digest format: sha256-<hex>
# ---------------------------------------------------------------------------
_ollama_blob_hot_refs() {
  local digest="$1"
  local sha="${digest#sha256-}"
  grep -rl "\"sha256:${sha}\"" "${HOT_OLLAMA_PATH}/models/manifests/" 2>/dev/null | wc -l
}

# ---------------------------------------------------------------------------
# ollama_migrate_model <model_name> <cold_base>
# Moves an Ollama model to cold storage with blob reference counting.
# Only migrates blobs whose hot reference count drops to 0 after this migration.
# Shared blobs (referenced by other models) are copied but not removed from hot.
# BLOCKS if Ollama server is active (user must stop it first).
# Guards: server stopped, cold mounted, sufficient space.
# ---------------------------------------------------------------------------
ollama_migrate_model() {
  local model_name="$1"
  local cold_base="$2"

  # Guard 1: BLOCK if Ollama server is active (SAFE-06)
  if ollama_check_server; then
    ms_die "Ollama server is active. Stop it first: systemctl stop ollama"
  fi

  # Guard 2: cold drive must be mounted (SAFE-01)
  check_cold_mounted "$cold_base"

  # Guard 3: sufficient space on cold drive (SAFE-02)
  local size
  size=$(ollama_get_model_size "$model_name")
  if ! check_space "$cold_base" "$size"; then
    return 1
  fi

  # Derive manifest path — handle model names with and without tag
  local model_base model_tag
  if [[ "$model_name" == *:* ]]; then
    model_base="${model_name%%:*}"
    model_tag="${model_name##*:}"
  else
    model_base="$model_name"
    model_tag="latest"
  fi
  local manifest_path="${HOT_OLLAMA_PATH}/models/manifests/registry.ollama.ai/library/${model_base}/${model_tag}"

  if [[ ! -f "$manifest_path" ]]; then
    ms_log "Manifest not found: $manifest_path"
    return 1
  fi

  # Derive relative path under manifests/ for cold target
  local manifest_rel="${manifest_path#${HOT_OLLAMA_PATH}/models/manifests/}"
  local cold_manifest_path="${cold_base}/ollama/models/manifests/${manifest_rel}"

  # Create cold target directories
  mkdir -p "$(dirname "$cold_manifest_path")"
  mkdir -p "${cold_base}/ollama/models/blobs"

  # Process each blob with reference counting
  local blob
  while IFS= read -r blob; do
    [[ -z "$blob" ]] && continue
    local hot_blob="${HOT_OLLAMA_PATH}/models/blobs/${blob}"
    local cold_blob="${cold_base}/ollama/models/blobs/${blob}"
    [[ -f "$hot_blob" || -L "$hot_blob" ]] || continue

    local ref_count
    ref_count=$(_ollama_blob_hot_refs "$blob")

    local rsync_flags="-a"
    [[ -t 1 ]] && rsync_flags+=" --info=progress2"
    if [[ "$ref_count" -le 1 ]]; then
      # Only this model references the blob — move it and create symlink
      rsync $rsync_flags "$hot_blob" "$cold_blob"
      rm "$hot_blob"
      ln -s "$cold_blob" "$hot_blob"
    else
      # Shared blob — copy to cold but leave hot copy intact
      rsync $rsync_flags "$hot_blob" "$cold_blob"
    fi
  done < <(_ollama_manifest_blobs "$manifest_path")

  # Copy manifest to cold
  cp "$manifest_path" "$cold_manifest_path"

  ms_log "Migrated Ollama model: $model_name -> ${cold_base}/ollama"
  return 0
}

# ---------------------------------------------------------------------------
# ollama_recall_model <model_name> <hot_base>
# Restores an Ollama model from cold storage to hot.
# For each blob that is a symlink on hot (was moved), removes symlink and restores.
# Blobs that are regular files (shared, were only copied) are left as-is.
# BLOCKS if Ollama server is active (user must stop it first).
# ---------------------------------------------------------------------------
ollama_recall_model() {
  local model_name="$1"
  local hot_base="$2"

  # Guard: BLOCK if Ollama server is active (SAFE-06)
  if ollama_check_server; then
    ms_die "Ollama server is active. Stop it first: systemctl stop ollama"
  fi

  # Derive manifest path
  local model_base model_tag
  if [[ "$model_name" == *:* ]]; then
    model_base="${model_name%%:*}"
    model_tag="${model_name##*:}"
  else
    model_base="$model_name"
    model_tag="latest"
  fi
  local manifest_path="${HOT_OLLAMA_PATH}/models/manifests/registry.ollama.ai/library/${model_base}/${model_tag}"

  # Find cold manifest — cold_base is passed as hot_base's corresponding cold storage
  # We need to look for the manifest in common cold paths
  # The cold_base for recall should be COLD_PATH, resolved via the symlink target
  # Derive cold manifest from the model's existing symlink or from COLD_PATH
  local cold_manifest_path
  # Try to find where this model's manifest is on cold via the hot blobs symlinks
  # Walk through hot manifests symlinks to find cold_base
  local blob
  local sample_blob
  sample_blob=$(jq -r '([.layers[].digest] + [.config.digest]) | .[0]' "$manifest_path" 2>/dev/null \
    | sed 's|sha256:|sha256-|')
  local hot_sample="${HOT_OLLAMA_PATH}/models/blobs/${sample_blob}"

  local cold_base
  if [[ -L "$hot_sample" ]]; then
    local link_target
    link_target=$(readlink -f "$hot_sample")
    # cold_base is the parent 3 levels up from the blob: cold_base/ollama/models/blobs/<blob>
    cold_base=$(dirname "$(dirname "$(dirname "$(dirname "$link_target")")")")
  else
    ms_log "No cold symlink found for $model_name blobs — model may not be migrated"
    return 1
  fi

  local manifest_rel="${manifest_path#${HOT_OLLAMA_PATH}/models/manifests/}"
  cold_manifest_path="${cold_base}/ollama/models/manifests/${manifest_rel}"

  if [[ ! -f "$cold_manifest_path" ]]; then
    ms_log "Cold manifest not found: $cold_manifest_path"
    return 1
  fi

  # Restore each blob that is a symlink on hot (was moved, not just copied)
  while IFS= read -r blob; do
    [[ -z "$blob" ]] && continue
    local hot_blob="${HOT_OLLAMA_PATH}/models/blobs/${blob}"
    local cold_blob="${cold_base}/ollama/models/blobs/${blob}"

    if [[ -L "$hot_blob" ]]; then
      # Was moved — remove symlink, restore from cold
      rm "$hot_blob"
      local rsync_flags="-a"
      [[ -t 1 ]] && rsync_flags+=" --info=progress2"
      rsync $rsync_flags "$cold_blob" "$hot_blob"
    fi
    # If regular file: shared blob that was only copied — already on hot, skip
  done < <(_ollama_manifest_blobs "$cold_manifest_path")

  # Remove cold manifest
  rm -f "$cold_manifest_path"

  # Clean up empty cold directories
  find "${cold_base}/ollama" -type d -empty -delete 2>/dev/null || true

  ms_log "Recalled Ollama model: $model_name"
  return 0
}
