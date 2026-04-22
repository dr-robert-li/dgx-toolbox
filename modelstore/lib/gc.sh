#!/usr/bin/env bash
# modelstore/lib/gc.sh — Garbage collection for incomplete/truncated models
# Sourced by gc.sh command — caller controls error handling.

_MS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_MS_LIB}/common.sh"
source "${_MS_LIB}/config.sh"

# ------ Garbage collection thresholds ----

# Models with a named parameter count (X B pattern) but actual size
# is less than this fraction of expected:
INCOMPLETE_RATIO=5

# Absolute size cutoff for models without any parameter count in the name
ABSOLUTE_CUTOFF_BYTES=104857600  # 100MB

# Default parameter size in bytes (fp16)
DEFAULT_PARAM_BYTES=2

# ------ Format bytes to human-readable ----

_fmt_bytes() {
  local bytes="$1"
  if [[ "$bytes" -ge 1073741824 ]]; then
    printf "%.1f GB" "$(echo "scale=1; $bytes / 1073741824" | bc 2>/dev/null || echo 0)"
  elif [[ "$bytes" -ge 1048576 ]]; then
    printf "%.1f MB" "$(echo "scale=1; $bytes / 1048576" | bc 2>/dev/null || echo 0)"
  else
    printf "%d B" "$bytes"
  fi
}

# ------ Expected size calculation ----

# Parse model name for parameter count: "X B", "X.B", "X.Y", etc.
# Returns: expected_size_in_bytes  expected_params  precision
# If no params found, prints "0 0 unknown"
gc_expected_size() {
  local model_dir="$1"
  local model_basename
  model_basename=$(basename "$model_dir")

  # Try to get a more descriptive name from config.json
  local model_path=""
  if [[ -f "${model_dir}/config.json" ]]; then
    model_path=$(jq -r '.name // .model_name // empty' "${model_dir}/config.json" 2>/dev/null | head -1)
  fi
  if [[ -z "$model_path" ]]; then
    model_path=$(find "${model_dir}" -name "config.json" -type f 2>/dev/null | head -1 | xargs jq -r '.name // .model_name // empty' 2>/dev/null | head -1)
  fi

  # Search in config file name, then directory name, for param count patterns
  local name_to_search="${model_path:-$model_basename}"

  # Pattern 1: "X B" or "X.B" (e.g., "30B", "4B", "0.5B", "1.5B", "3.1B")
  local params
  params=$(echo "$name_to_search" | grep -oP '(0\.[0-9]+|[1-9][0-9]*(\.[0-9]+)?)B' | grep -oP '[0-9]*\.?[0-9]+' | head -1)

  # Pattern 2: "X Y" where Y is a large number that could be params in billions
  if [[ -z "$params" ]]; then
    local numbers
    numbers=$(echo "$name_to_search" | grep -oP '(?<![.\w])[1-9][0-9]{8,}(?!\w)' | awk '{printf "%.0f\n", $1/1e9}' | head -1)
    [[ -n "$numbers" ]] && params="$numbers"
  fi

  # Pattern 3: Look for "X B" in the full path as fallback
  if [[ -z "$params" ]]; then
    params=$(echo "$model_dir" | grep -oP '(0\.[0-9]+|[1-9][0-9]*(\.[0-9]+)?)B' | grep -oP '[0-9]*\.?[0-9]+' | head -1)
  fi

  if [[ -z "$params" || "$params" == "0" ]]; then
    echo "0 0 unknown"
    return
  fi

  local expected_bytes
  expected_bytes=$(echo "$params * $DEFAULT_PARAM_BYTES * 1073741824" | bc 2>/dev/null | cut -d. -f1)

  # Also report params for display
  local expected_params_mb
  expected_params_mb=$(echo "$params * 1000" | bc 2>/dev/null | cut -d. -f1)

  echo "${expected_bytes:-0} ${expected_params_mb}fp ${DEFAULT_PARAM_BYTES}"
}

# ------ Check if model has actual weight files ----

gc_has_weights() {
  local model_dir="$1"

  # Search recursively for common weight file extensions
  find "$model_dir" -type f \( \
    -name "*.safetensors" -o \
    -name "*.gguf" -o \
    -name "*.bin" -o \
    -name "*.pt" -o \
    -name "*.pth" -o \
    -name "*.ckpt" -o \
    -name "*.ggv" -o \
    -name "*.mlx" -o \
    -name "*.onnx" \
  \) 2>/dev/null | head -1 | wc -l | tr -d ' '
}

# ------ Check model usage ----

gc_get_last_used() {
  local model_path="$1"
  local usage_file="${HOME}/.modelstore/usage.json"
  local audit_log="${HOME}/.modelstore/audit.log"

  # Check usage.json first
  if [[ -f "$usage_file" ]]; then
    local last_used
    last_used=$(jq -r --arg k "$model_path" '.[$k] // empty' "$usage_file" 2>/dev/null)
    if [[ -n "$last_used" ]]; then
      echo "$last_used"
      return
    fi
  fi

  # Check audit log
  if [[ -f "$audit_log" ]]; then
    local last_audit
    last_audit=$(grep "\"model\":\"${model_path}\"" "$audit_log" 2>/dev/null | tail -1 | jq -r '.timestamp // empty' 2>/dev/null)
    if [[ -n "$last_audit" ]]; then
      echo "$last_audit"
      return
    fi
  fi

  echo "never"
}

# ------ Detect incomplete models ----

# Scans all HF models and outputs GC findings as TSV:
# path<TAB>name<TAB>size<TAB>expected_size<TAB>expected_params<TAB>has_weights<TAB>last_used<TAB>reason
gc_find_incomplete() {
  load_config

  while IFS= read -r model_dir; do
    [[ -z "$model_dir" ]] && continue
    [[ -d "$model_dir" ]] || continue

    local name size_bytes expected_bytes expected_params has_weights last_used reason
    name=$(basename "$model_dir")
    size_bytes=$(du -sb "$model_dir" 2>/dev/null | cut -f1 || echo 0)
    expected_params=$(gc_expected_size "$model_dir" | awk '{print $2}')
    expected_bytes=$(gc_expected_size "$model_dir" | awk '{print $1}')
    has_weights=$(gc_has_weights "$model_dir")
    last_used=$(gc_get_last_used "$model_dir")

    reason=""

    # Rule 1: Has weight files — skip (definitely usable)
    if [[ "$has_weights" -gt 0 ]]; then
      continue
    fi

    # Rule 2: No params in name and under absolute cutoff — likely junk
    if [[ "$expected_params" == "0" ]]; then
      if [[ "$size_bytes" -lt "$ABSOLUTE_CUTOFF_BYTES" ]]; then
        reason="under ${ABSOLUTE_CUTOFF_BYTES/1048576/100}MB with no size designation"
      else
        continue
      fi
    else
      # Rule 3: Has params in name but under ratio threshold of expected size
      local threshold
      threshold=$(( expected_bytes * INCOMPLETE_RATIO / 100 ))
      if [[ "$size_bytes" -lt "$threshold" ]]; then
        reason="incomplete ($(_fmt_bytes "$size_bytes") vs ~$(_fmt_bytes "$expected_bytes"))"
      else
        continue
      fi
    fi

    # Rule 4: Never used and no weights
    if [[ "$last_used" == "never" && -z "$reason" ]]; then
      reason="never used, no weights"
    fi

    # Only report if we have a reason
    [[ -z "$reason" ]] && continue

    # Format expected display
    local expected_display
    if [[ "$expected_params" != "0" && "$expected_params" != "unknown" ]]; then
      expected_display="${expected_params}B (~$(_fmt_bytes "$expected_bytes"))"
    else
      expected_display="< 100MB"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$model_dir" "$name" "$size_bytes" "$expected_bytes" "$expected_params" "$has_weights" "$last_used" "$reason"
  done < <(find "${HOT_HF_PATH}" -maxdepth 1 -name "models--*" 2>/dev/null | sort)
}
