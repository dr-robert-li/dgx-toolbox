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
# ollama_migrate_model <model_name> <cold_base>
# Stub with correct guard structure for Phase 3 implementation.
# BLOCKS if Ollama server is active (user must stop it first).
# Guards: server stopped, cold mounted, sufficient space.
# Phase 3 will implement: ollama cp to cold path + ollama rm from hot.
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

  ms_log "Ollama migration deferred to Phase 3 (ollama cp + ollama rm)"
  return 0
}

# ---------------------------------------------------------------------------
# ollama_recall_model <model_name> <hot_base>
# Stub with correct guard structure for Phase 3 implementation.
# BLOCKS if Ollama server is active (user must stop it first).
# Phase 3 will implement: restore model from cold path + ollama rm cold copy.
# ---------------------------------------------------------------------------
ollama_recall_model() {
  local model_name="$1"
  local hot_base="$2"

  # Guard: BLOCK if Ollama server is active (SAFE-06)
  if ollama_check_server; then
    ms_die "Ollama server is active. Stop it first: systemctl stop ollama"
  fi

  ms_log "Ollama recall deferred to Phase 3"
  return 0
}
