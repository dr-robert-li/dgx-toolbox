#!/usr/bin/env bash
# modelstore/cmd/gc.sh — Garbage collection: find and delete incomplete/truncated models
# Usage: modelstore gc [--dry-run] [--delete-all]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/config.sh"
source "${SCRIPT_DIR}/../lib/audit.sh"
source "${SCRIPT_DIR}/../lib/gc.sh"

load_config

# ------ Parse flags ----
DRY_RUN=false
DELETE_ALL=false
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=true ;;
    --delete-all) DELETE_ALL=true ;;
    *)            ARGS+=("$arg") ;;
  esac
done

# ------ Delete helper ----

_delete_model() {
  local model_path="$1"
  local model_name="$2"
  local size_bytes="$3"

  if [[ "$DRY_RUN" == true ]]; then
    echo "  [DRY RUN] Would delete: ${model_name} ($(_fmt_bytes "$size_bytes"))"
    return
  fi

  # Remove actual directory (not symlinks — cold models are not gc target)
  if [[ -d "$model_path" && ! -L "$model_path" ]]; then
    rm -rf "$model_path"
    echo "  Deleted: ${model_name} ($(_fmt_bytes "$size_bytes"))"
    audit_log "gc_delete" "$model_name" "$size_bytes" "$model_path" "none" 0 "gc"
  elif [[ -L "$model_path" ]]; then
    # Broken symlink — remove it
    rm -f "$model_path"
    echo "  Removed dangling symlink: ${model_name}"
    audit_log "gc_delete" "$model_name" 0 "$model_path" "none" 0 "gc"
  else
    echo "  Skipped (not found): ${model_name}"
  fi
}

# ------ Scan for garbage ----
echo ""
echo "== Model Store Garbage Collection =="
echo ""

# Collect results
declare -a GC_PATHS=()
declare -a GC_NAMES=()
declare -a GC_SIZES=()
declare -a GC_EXPECTED=()
declare -a GC_PARAMS=()
declare -a GC_REASONS=()
declare -a GC_LASTUSED=()

while IFS=$'\t' read -r path name size expected params has_weights last_used reason; do
  [[ -z "$path" ]] && continue
  GC_PATHS+=("$path")
  GC_NAMES+=("$name")
  GC_SIZES+=("$size")
  GC_EXPECTED+=("$expected")
  GC_PARAMS+=("$params")
  GC_REASONS+=("$reason")
  GC_LASTUSED+=("$last_used")
done < <(gc_find_incomplete)

count=${#GC_PATHS[@]}
if [[ "$count" -eq 0 ]]; then
  echo "No incomplete or unused models found."
  echo ""
  exit 0
fi

# Sort by size ascending (smallest first — most likely junk)
indices=()
for (( i = 0; i < count; i++ )); do indices+=($i); done
for (( i = 0; i < count; i++ )); do
  for (( j = 0; j < count - i - 1; j++ )); do
    ai=${indices[$j]}
    bi=${indices[$(( j + 1 ))]}
    if [[ "${GC_SIZES[$ai]}" -gt "${GC_SIZES[$bi]}" ]]; then
      tmp=${indices[$j]}
      indices[$j]=${indices[$(( j + 1 ))]}
      indices[$(( j + 1 ))]=$tmp
    fi
  done
done

# ------ Display results ----

echo "Found ${count} incomplete/truncated model(s):"
echo ""
printf "  %4s  %-12s  %-25s  %-20s  %s\n" "#" "SIZE" "EXPECTED" "LAST USED" "REASON"
printf "  %4s  %-12s  %-25s  %-20s  %s\n" "----" "-----" "-----" "-----" "-----"

for idx in "${indices[@]}"; do
  sz_str=$(_fmt_bytes "${GC_SIZES[$idx]}")
  exp_str=""
  if [[ "${GC_PARAMS[$idx]}" != "0" && "${GC_PARAMS[$idx]}" != "unknown" ]]; then
    exp_str="${GC_PARAMS[$idx]}B (~$(_fmt_bytes "${GC_EXPECTED[$idx]}"))"
  else
    exp_str="< 100MB"
  fi
  last="${GC_LASTUSED[$idx]}"
  [[ "$last" == "never" ]] && last="never"

  printf "  %4d  %-12s  %-25s  %-20s  %s\n" \
    "$(( idx + 1 ))" "$sz_str" "$exp_str" "$last" "${GC_REASONS[$idx]}"
done

total_bytes=0
for idx in "${indices[@]}"; do
  total_bytes=$(( total_bytes + GC_SIZES[$idx] ))
done
echo ""
echo "Total reclaimable: $(_fmt_bytes "$total_bytes")"

# ------ Interactive selection ----

if [[ "$DELETE_ALL" == true ]]; then
  echo ""
  echo "Deleting all ${count} incomplete model(s)..."
  for idx in "${indices[@]}"; do
    _delete_model "${GC_PATHS[$idx]}" "${GC_NAMES[$idx]}" "${GC_SIZES[$idx]}"
  done
  echo "Done."
  exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
  echo ""
  echo "== DRY RUN — no files deleted =="
  echo "To actually delete: modelstore gc --delete-all"
  echo "Or select individually: modelstore gc"
  exit 0
fi

# Ask user
echo ""
echo "What would you like to do?"
echo "  1) Delete ALL ${count} incomplete model(s) ($(_fmt_bytes "$total_bytes"))"
echo "  2) Select individual models to delete"
echo "  3) Keep all (do nothing)"
read -r -p "Choice [1-3]: " choice

case "$choice" in
  1)
    echo ""
    echo "Deleting all ${count} incomplete model(s)..."
    for idx in "${indices[@]}"; do
      _delete_model "${GC_PATHS[$idx]}" "${GC_NAMES[$idx]}" "${GC_SIZES[$idx]}"
    done
    ;;
  2)
    echo ""
    echo "Enter model numbers to delete (comma-separated, or 'all' to select all):"
    read -r -p "Selection: " selection
    if [[ "$selection" == "all" ]]; then
      for idx in "${indices[@]}"; do
        _delete_model "${GC_PATHS[$idx]}" "${GC_NAMES[$idx]}" "${GC_SIZES[$idx]}"
      done
    else
      IFS=',' read -ra nums <<< "$selection"
      for num in "${nums[@]}"; do
        num=$(echo "$num" | tr -d ' ')
        if [[ "$num" =~ ^[0-9]+$ && "$num" -ge 1 && "$num" -le "$count" ]]; then
          actual_idx=$(( num - 1 ))
          _delete_model "${GC_PATHS[$actual_idx]}" "${GC_NAMES[$actual_idx]}" "${GC_SIZES[$actual_idx]}"
        fi
      done
    fi
    ;;
  3)
    echo "Keeping all models."
    ;;
  *)
    echo "Invalid choice."
    ;;
esac

echo ""
echo "Done."
