#!/usr/bin/env bash
set -euo pipefail

# demo-autoresearch.sh — End-to-end autoresearch pipeline demo
#
# Orchestrates the full data-to-inference pipeline:
#   1. Prerequisites check
#   2. Data source selection (6-option menu)
#   3. Optional training data screening through safety harness
#   4. DGX Spark GPU tuning
#   5. Autoresearch training (limited to DEMO_CYCLES cycles)
#   6. Post-training safety eval (eval-checkpoint.sh)
#   7. Final summary with curl command
#
# Usage: demo-autoresearch.sh
#
# Environment variables:
#   DEMO_CYCLES       Number of training cycles to run (default: 3)
#   HARNESS_URL       Safety harness URL (default: http://localhost:5000)
#   HARNESS_API_KEY   API key for harness (optional — needed only for screening)

# ---------------------------------------------------------------------------
# Section 0 — Constants and helpers
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_DIR/lib.sh"
source "$PROJECT_DIR/karpathy-autoresearch/spark-config.sh"

DEMO_CYCLES="${DEMO_CYCLES:-3}"
HARNESS_URL="${HARNESS_URL:-http://localhost:5000}"
AUTORESEARCH_DIR="${HOME}/autoresearch"
AUTORESEARCH_REPO="https://github.com/karpathy/autoresearch.git"
DEMO_LOG="${PROJECT_DIR}/demo-training.log"
TRAINING_PID=""

# Color/formatting helpers
_bold() { printf '\033[1m%s\033[0m' "$1"; }
_green() { printf '\033[32m%s\033[0m' "$1"; }
_yellow() { printf '\033[33m%s\033[0m' "$1"; }
_red() { printf '\033[31m%s\033[0m' "$1"; }

# Summary state
SUMMARY_DATASET="(not set)"
SUMMARY_CYCLES=0
SUMMARY_SCREENING="skipped"
SUMMARY_EVAL_RESULT="unknown"
SUMMARY_F1="0.00"
SUMMARY_MODEL_NAME=""
SUMMARY_CHECKPOINT=""

# ---------------------------------------------------------------------------
# Cleanup trap — kill background training process on exit
# ---------------------------------------------------------------------------
_cleanup() {
  if [ -n "$TRAINING_PID" ] && kill -0 "$TRAINING_PID" 2>/dev/null; then
    echo ""
    echo "Stopping background training process (PID $TRAINING_PID)..."
    kill "$TRAINING_PID" 2>/dev/null || true
    wait "$TRAINING_PID" 2>/dev/null || true
  fi
}
trap '_cleanup' EXIT

# ---------------------------------------------------------------------------
# Helper: discover local datasets in ~/data/
# ---------------------------------------------------------------------------
_discover_local_datasets() {
  local found=0
  while IFS= read -r -d '' subdir; do
    local name
    name=$(basename "$subdir")
    local count
    count=$(find "$subdir" -maxdepth 1 \( -name "*.txt" -o -name "*.parquet" -o -name "*.jsonl" \) | wc -l)
    echo "${name} (${count} files)"
    found=1
  done < <(find "${HOME}/data" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
  if [ "$found" -eq 0 ]; then
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Section 1 — Banner
# ---------------------------------------------------------------------------
printf '\n'
printf '========================================\n'
printf '  AUTORESEARCH PIPELINE DEMO\n'
printf '  Cycles: %s | Harness: %s\n' "$DEMO_CYCLES" "$HARNESS_URL"
printf '========================================\n'
printf '\n'

# ---------------------------------------------------------------------------
# Section 1 — Prerequisites check
# ---------------------------------------------------------------------------
printf '[1/7] Checking prerequisites...\n'

# Prompt for HF_TOKEN if not set (enables higher rate limits and faster downloads)
if [ -z "${HF_TOKEN:-}" ]; then
  printf '  HuggingFace token not set. Set HF_TOKEN for faster downloads and private model access.\n'
  printf '  Get one at: https://huggingface.co/settings/tokens\n'
  read -rp "  Enter HF_TOKEN (or press Enter to skip): " _hf_token
  if [ -n "$_hf_token" ]; then
    export HF_TOKEN="$_hf_token"
    printf '  HF_TOKEN set for this session.\n'
  else
    printf '  Continuing without HF_TOKEN (public models only, slower downloads).\n'
  fi
else
  printf '  HF_TOKEN: set\n'
fi

# Fix HF cache permissions (Docker containers often create dirs as root)
HF_CACHE="${HOME}/.cache/huggingface"
if [ -d "$HF_CACHE" ]; then
  HF_OWNER=$(stat -c '%U' "$HF_CACHE" 2>/dev/null || echo "unknown")
  if [ "$HF_OWNER" != "$USER" ]; then
    printf '  Fixing HuggingFace cache permissions (owned by %s, reclaiming for %s)...\n' "$HF_OWNER" "$USER"
    sudo chown -R "$USER:$USER" "$HF_CACHE" 2>/dev/null || {
      printf '  %s: Could not fix HF cache permissions. Training may fail.\n' "$(_yellow "WARNING")"
      printf '  Run manually: sudo chown -R %s:%s %s\n' "$USER" "$USER" "$HF_CACHE"
    }
  fi
fi

# Check/clone autoresearch repo
if [ -d "$AUTORESEARCH_DIR/.git" ]; then
  printf '  autoresearch: found at %s\n' "$AUTORESEARCH_DIR"
  cd "$AUTORESEARCH_DIR"
  git pull origin master --quiet 2>/dev/null || printf '  WARNING: Could not pull latest autoresearch (offline?). Continuing with existing clone.\n'
else
  printf '  Cloning karpathy/autoresearch into %s...\n' "$AUTORESEARCH_DIR"
  git clone "$AUTORESEARCH_REPO" "$AUTORESEARCH_DIR" || {
    printf 'ERROR: Failed to clone autoresearch from %s\n' "$AUTORESEARCH_REPO" >&2
    exit 1
  }
fi

# Check uv
if ! command -v uv &>/dev/null; then
  printf '  uv not found — installing via astral.sh...\n'
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

# Run uv sync
printf '  Running uv sync...\n'
cd "$AUTORESEARCH_DIR"
uv sync --quiet 2>/dev/null || printf '  WARNING: uv sync reported errors. Continuing anyway.\n'

# Check harness reachability
HARNESS_REACHABLE=0
if curl -sf -X POST "${HARNESS_URL}/probe" \
   -H "Authorization: Bearer ${HARNESS_API_KEY:-sk-devteam-test}" \
   --max-time 5 >/dev/null 2>&1; then
  HARNESS_REACHABLE=1
  printf '  Harness: reachable at %s\n' "$HARNESS_URL"
else
  printf '  %s: harness not reachable at %s (screening and eval will skip gracefully)\n' \
    "$(_yellow "WARNING")" "$HARNESS_URL"
fi

# Check vLLM/Ollama (informational only)
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^vllm$"; then
  printf '  vLLM: running (:8020)\n'
elif curl -sf http://localhost:11434/api/tags --max-time 3 >/dev/null 2>&1; then
  printf '  Ollama: running (:11434)\n'
else
  printf '  Inference: no vLLM or Ollama detected (model registration will use vLLM)\n'
fi

printf '\n'

# ---------------------------------------------------------------------------
# Section 2 — Data source selection
# ---------------------------------------------------------------------------
printf '[2/7] Select training data source:\n\n'

DATA_SOURCE_LABEL=""

select src in \
  "Default (autoresearch built-in)" \
  "Local directory" \
  "Hugging Face dataset" \
  "GitHub repo" \
  "Kaggle dataset" \
  "Local datasets (auto-discovered)"; do
  case "$src" in
    "Default (autoresearch built-in)")
      DATA_SOURCE_LABEL="default"
      printf '\n  Using autoresearch built-in dataset...\n'
      cd "$AUTORESEARCH_DIR"
      uv run prepare.py
      break
      ;;

    "Local directory")
      DATA_SOURCE_LABEL="local"
      printf '\n'
      read -rp "  Path to local data directory: " LOCAL_DATA_PATH
      if [ ! -d "$LOCAL_DATA_PATH" ]; then
        printf 'ERROR: Directory not found: %s\n' "$LOCAL_DATA_PATH" >&2
        exit 1
      fi
      printf '  Copying .txt and .parquet files into data/...\n'
      mkdir -p "$AUTORESEARCH_DIR/data"
      find "$LOCAL_DATA_PATH" -maxdepth 2 \( -name "*.txt" -o -name "*.parquet" \) \
        -exec cp {} "$AUTORESEARCH_DIR/data/" \;
      cd "$AUTORESEARCH_DIR"
      uv run prepare.py
      break
      ;;

    "Hugging Face dataset")
      DATA_SOURCE_LABEL="huggingface"
      printf '\n'
      read -rp "  HuggingFace dataset name (e.g. karpathy/climbmix-400b-shuffle): " HF_DATASET
      if [ -z "$HF_DATASET" ]; then
        printf 'ERROR: Dataset name cannot be empty.\n' >&2
        exit 1
      fi
      export AUTORESEARCH_HF_DATASET="$HF_DATASET"
      DATA_SOURCE_LABEL="huggingface:${HF_DATASET}"
      cd "$AUTORESEARCH_DIR"
      printf '  Attempting prepare.py with AUTORESEARCH_HF_DATASET=%s...\n' "$HF_DATASET"
      if ! uv run prepare.py 2>&1 | grep -qi "error\|traceback"; then
        printf '  prepare.py completed using HF dataset.\n'
      else
        printf '  Downloading via huggingface-cli into data/...\n'
        mkdir -p "$AUTORESEARCH_DIR/data"
        uv run -- huggingface-cli download "$HF_DATASET" \
          --local-dir "$AUTORESEARCH_DIR/data/" \
          --repo-type dataset
        uv run prepare.py
      fi
      break
      ;;

    "GitHub repo")
      DATA_SOURCE_LABEL="github"
      printf '\n'
      read -rp "  GitHub repo URL (e.g. https://github.com/user/repo): " GITHUB_URL
      if [ -z "$GITHUB_URL" ]; then
        printf 'ERROR: Repo URL cannot be empty.\n' >&2
        exit 1
      fi
      GITHUB_TMP="$(mktemp -d)"
      printf '  Cloning %s...\n' "$GITHUB_URL"
      git clone --depth=1 "$GITHUB_URL" "$GITHUB_TMP/repo"
      printf '  Copying .txt and .parquet files into data/...\n'
      mkdir -p "$AUTORESEARCH_DIR/data"
      find "$GITHUB_TMP/repo" -maxdepth 4 \( -name "*.txt" -o -name "*.parquet" \) \
        -exec cp {} "$AUTORESEARCH_DIR/data/" \;
      rm -rf "$GITHUB_TMP"
      DATA_SOURCE_LABEL="github:${GITHUB_URL}"
      cd "$AUTORESEARCH_DIR"
      uv run prepare.py
      break
      ;;

    "Kaggle dataset")
      DATA_SOURCE_LABEL="kaggle"
      printf '\n'
      if ! command -v kaggle &>/dev/null; then
        printf 'ERROR: kaggle CLI not installed. Install with: pip install kaggle\n' >&2
        exit 1
      fi
      read -rp "  Kaggle dataset identifier (e.g. user/dataset-name): " KAGGLE_ID
      if [ -z "$KAGGLE_ID" ]; then
        printf 'ERROR: Dataset identifier cannot be empty.\n' >&2
        exit 1
      fi
      mkdir -p "$AUTORESEARCH_DIR/data"
      kaggle datasets download -d "$KAGGLE_ID" -p "$AUTORESEARCH_DIR/data/" --unzip
      DATA_SOURCE_LABEL="kaggle:${KAGGLE_ID}"
      cd "$AUTORESEARCH_DIR"
      uv run prepare.py
      break
      ;;

    "Local datasets (auto-discovered)")
      DATA_SOURCE_LABEL="local-datasets"
      printf '\n'
      mapfile -t DATASET_NAMES < <(_discover_local_datasets 2>/dev/null)
      if [ ${#DATASET_NAMES[@]} -eq 0 ]; then
        printf 'ERROR: No datasets found in ~/data/\n' >&2
        exit 1
      fi
      printf '  Available datasets in ~/data/:\n'
      select dataset_entry in "${DATASET_NAMES[@]}"; do
        if [ -n "$dataset_entry" ]; then
          CHOSEN_DATASET="${dataset_entry%% (*}"
          LOCAL_DATASET_PATH="${HOME}/data/${CHOSEN_DATASET}"
          printf '  Selected: %s\n' "$CHOSEN_DATASET"
          DATA_SOURCE_LABEL="local-datasets:${CHOSEN_DATASET}"
          mkdir -p "$AUTORESEARCH_DIR/data"
          find "$LOCAL_DATASET_PATH" -maxdepth 1 \
            \( -name "*.txt" -o -name "*.parquet" -o -name "*.jsonl" \) \
            -exec cp {} "$AUTORESEARCH_DIR/data/" \;
          cd "$AUTORESEARCH_DIR"
          uv run prepare.py
          break
        fi
      done
      break
      ;;

    *)
      printf '  Invalid option — enter a number between 1 and 6.\n'
      ;;
  esac
done

SUMMARY_DATASET="$DATA_SOURCE_LABEL"
printf '\n  Data source configured: %s\n\n' "$DATA_SOURCE_LABEL"

# ---------------------------------------------------------------------------
# Section 3 — Optional data screening
# ---------------------------------------------------------------------------
printf '[3/7] Training data screening (optional)\n'

SCREEN_ANSWER="n"
if [ "$HARNESS_REACHABLE" = "1" ]; then
  read -rp "  Screen training data through safety harness? (y/N) " SCREEN_ANSWER
  SCREEN_ANSWER="${SCREEN_ANSWER:-n}"
else
  printf '  Skipping — harness not reachable.\n'
fi

if [[ "$SCREEN_ANSWER" =~ ^[Yy]$ ]]; then
  if [ -z "${HARNESS_API_KEY:-}" ]; then
    read -rsp "  HARNESS_API_KEY not set. Enter non-bypass key (e.g. sk-devteam-test): " HARNESS_API_KEY
    export HARNESS_API_KEY
    printf '\n'
  fi

  # Find a data file to screen
  DATA_FILE=""
  for candidate in "$AUTORESEARCH_DIR/data/train.jsonl" \
                   "$AUTORESEARCH_DIR/data/train.txt"; do
    if [ -f "$candidate" ]; then
      DATA_FILE="$candidate"
      break
    fi
  done
  # Fall back to first .jsonl or .txt in data/
  if [ -z "$DATA_FILE" ]; then
    DATA_FILE=$(find "$AUTORESEARCH_DIR/data" -maxdepth 1 \( -name "*.jsonl" -o -name "*.txt" \) | head -1 2>/dev/null || true)
  fi

  if [ -n "$DATA_FILE" ]; then
    printf '  Screening: %s\n' "$DATA_FILE"
    if SCREEN_OUTPUT=$(HARNESS_URL="$HARNESS_URL" HARNESS_API_KEY="$HARNESS_API_KEY" \
        "$SCRIPT_DIR/screen-data.sh" "$DATA_FILE" 2>&1); then
      SCREENED_COUNT=$(printf '%s' "$SCREEN_OUTPUT" | grep -oE '[0-9]+ clean' | grep -oE '^[0-9]+' || echo "?")
      REMOVED_COUNT=$(printf '%s' "$SCREEN_OUTPUT" | grep -oE '[0-9]+ removed' | grep -oE '^[0-9]+' || echo "?")
      SUMMARY_SCREENING="${SCREENED_COUNT} clean / ${REMOVED_COUNT} removed"
      printf '  Result: %s clean, %s removed\n' "$SCREENED_COUNT" "$REMOVED_COUNT"
      printf '  Screened file written alongside original.\n'
    else
      printf '  %s: Screening failed (exit %s). Check harness logs. Continuing with unscreened data.\n' \
        "$(_yellow "WARNING")" "$?"
      SUMMARY_SCREENING="attempted but failed"
    fi
  else
    printf '  No .jsonl or .txt data files found to screen. Skipping.\n'
    SUMMARY_SCREENING="no files to screen"
  fi
else
  SUMMARY_SCREENING="skipped"
fi

printf '\n'

# ---------------------------------------------------------------------------
# Section 4 — Apply DGX Spark tuning
# ---------------------------------------------------------------------------
printf '[4/7] Applying DGX Spark GPU tuning...\n'

cd "$AUTORESEARCH_DIR"
if [ -f "$AUTORESEARCH_DIR/train.py" ]; then
  apply_spark_config "$AUTORESEARCH_DIR/train.py"
  apply_spark_timing "$AUTORESEARCH_DIR/train.py"
  printf '  Spark tuning applied.\n'
else
  printf '  %s: train.py not found at %s — skipping tuning\n' "$(_yellow "WARNING")" "$AUTORESEARCH_DIR/train.py"
fi

printf '\n'

# ---------------------------------------------------------------------------
# Section 5 — Run autoresearch training (limited to DEMO_CYCLES cycles)
# ---------------------------------------------------------------------------
printf '[5/7] Running autoresearch training (%s cycles, ~%s min each)...\n' \
  "$DEMO_CYCLES" "$SPARK_TRAIN_MINUTES"
printf '  Log: %s\n\n' "$DEMO_LOG"

cd "$AUTORESEARCH_DIR"

# Start training in background, tee output to terminal and log file
# Use a subshell so we can capture the PID reliably
uv run train.py 2>&1 | tee "$DEMO_LOG" &
TRAINING_PID=$!
sleep 2

# Cycle-limiting monitor: watch log for "Cycle N" completion patterns
# and send SIGTERM after DEMO_CYCLES complete cycles
_monitor_cycles() {
  local cycles_seen=0
  local max_cycles="$1"
  local log_file="$2"
  local train_pid="$3"

  # Poll log file for cycle completion markers
  while kill -0 "$train_pid" 2>/dev/null; do
    if [ -f "$log_file" ]; then
      local new_count
      new_count=$(grep -cE "(Cycle [0-9]+ complete|step [0-9]+.*loss|experiment [0-9]+)" "$log_file" 2>/dev/null | tr -d '[:space:]')
      new_count="${new_count:-0}"
      if [ "$new_count" -gt "$cycles_seen" ]; then
        cycles_seen="$new_count"
        printf '\n  [Cycle monitor] Detected %s/%s training iterations complete\n' \
          "$cycles_seen" "$max_cycles"
      fi
      if [ "$cycles_seen" -ge "$max_cycles" ]; then
        printf '\n  [Cycle monitor] %s cycles complete — sending SIGTERM to training process\n' "$max_cycles"
        kill -TERM "$train_pid" 2>/dev/null || true
        return 0
      fi
    fi
    sleep 15
  done
}

# Also set time-based fallback: DEMO_CYCLES * SPARK_TRAIN_MINUTES * 60 + 60s buffer
MAX_WAIT=$(( DEMO_CYCLES * SPARK_TRAIN_MINUTES * 60 + 60 ))

if [ -n "$TRAINING_PID" ]; then
  # Run cycle monitor in background
  _monitor_cycles "$DEMO_CYCLES" "$DEMO_LOG" "$TRAINING_PID" &
  MONITOR_PID=$!

  # Wait for training to finish (normally or via SIGTERM) with timeout
  ELAPSED=0
  while kill -0 "$TRAINING_PID" 2>/dev/null && [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
    sleep 30
    ELAPSED=$((ELAPSED + 30))
  done

  # Kill monitor
  kill "$MONITOR_PID" 2>/dev/null || true
  wait "$MONITOR_PID" 2>/dev/null || true

  # If training still running after timeout, stop it
  if kill -0 "$TRAINING_PID" 2>/dev/null; then
    printf '\n  [Timeout] Stopping training after %ss\n' "$ELAPSED"
    kill -TERM "$TRAINING_PID" 2>/dev/null || true
    sleep 5
    kill -KILL "$TRAINING_PID" 2>/dev/null || true
  fi

  wait "$TRAINING_PID" 2>/dev/null || true
  TRAINING_PID=""
fi

SUMMARY_CYCLES="$DEMO_CYCLES"
printf '\n  Training complete. Log saved to: %s\n\n' "$DEMO_LOG"

# ---------------------------------------------------------------------------
# Section 6 — Post-training safety eval
# ---------------------------------------------------------------------------
printf '[6/7] Running post-training safety eval...\n'

# Find the latest checkpoint: HF-format dir with config.json
CHECKPOINT_DIR=""

# Common autoresearch checkpoint locations
for search_base in \
    "$AUTORESEARCH_DIR/experiments" \
    "$AUTORESEARCH_DIR/out" \
    "$AUTORESEARCH_DIR/checkpoints" \
    "$AUTORESEARCH_DIR"; do
  if [ -d "$search_base" ]; then
    # Find most recent directory containing config.json
    FOUND=$(find "$search_base" -maxdepth 4 -name "config.json" -printf '%T@ %h\n' 2>/dev/null \
      | sort -rn | head -1 | awk '{print $2}' || true)
    if [ -n "$FOUND" ] && [ -d "$FOUND" ]; then
      CHECKPOINT_DIR="$FOUND"
      break
    fi
  fi
done

if [ -z "$CHECKPOINT_DIR" ]; then
  printf '\n  %s: No HuggingFace-format checkpoint found (no config.json in %s).\n' \
    "$(_yellow "WARNING")" "$AUTORESEARCH_DIR"
  printf '  Checkpoint saved raw at: %s\n' "$AUTORESEARCH_DIR"
  printf '  Run eval manually when checkpoint is ready:\n'
  printf '    scripts/eval-checkpoint.sh <path-to-checkpoint>\n\n'
  SUMMARY_EVAL_RESULT="no checkpoint found"
else
  printf '  Checkpoint: %s\n' "$CHECKPOINT_DIR"
  SUMMARY_CHECKPOINT="$CHECKPOINT_DIR"

  EVAL_EXIT=0
  "$SCRIPT_DIR/eval-checkpoint.sh" "$CHECKPOINT_DIR" || EVAL_EXIT=$?

  EVAL_JSON="${CHECKPOINT_DIR}/safety-eval.json"
  if [ -f "$EVAL_JSON" ]; then
    SUMMARY_F1=$(python3 -c "import json; d=json.load(open('$EVAL_JSON')); print(f\"{d.get('f1',0):.2f}\")" 2>/dev/null || echo "0.00")
    PASSED=$(python3 -c "import json; d=json.load(open('$EVAL_JSON')); print(d.get('passed',False))" 2>/dev/null || echo "False")
    REGISTERED=$(python3 -c "import json; d=json.load(open('$EVAL_JSON')); print(d.get('registered',False))" 2>/dev/null || echo "False")
    EXPERIMENT_NAME=$(python3 -c "import json; d=json.load(open('$EVAL_JSON')); print(d.get('experiment_name','unknown'))" 2>/dev/null || echo "unknown")
    SUMMARY_MODEL_NAME="autoresearch/${EXPERIMENT_NAME}"

    if [ "$PASSED" = "True" ]; then
      SUMMARY_EVAL_RESULT="PASS"
    else
      SUMMARY_EVAL_RESULT="FAIL"
    fi
  else
    SUMMARY_EVAL_RESULT="eval error (no safety-eval.json)"
    PASSED="False"
    REGISTERED="False"
  fi
fi

printf '\n'

# ---------------------------------------------------------------------------
# Section 7 — Print final summary
# ---------------------------------------------------------------------------
printf '[7/7] Demo complete.\n\n'

printf '========================================\n'
printf '  AUTORESEARCH DEMO COMPLETE\n'
printf '========================================\n'
printf '  Dataset:        %s\n' "$SUMMARY_DATASET"
printf '  Training:       %s cycles completed\n' "$SUMMARY_CYCLES"
printf '  Screening:      %s\n' "$SUMMARY_SCREENING"
printf '  Safety eval:    %s (F1: %s)\n' "$SUMMARY_EVAL_RESULT" "$SUMMARY_F1"

if [ "$SUMMARY_EVAL_RESULT" = "PASS" ] && [ -n "$SUMMARY_MODEL_NAME" ]; then
  printf '  Registered as:  %s\n' "$SUMMARY_MODEL_NAME"
  printf '\n  Query the model:\n'
  printf '  curl -s -X POST %s/v1/chat/completions \\\n' "$HARNESS_URL"
  printf '    -H "Authorization: Bearer sk-devteam-test" \\\n'
  printf '    -H "Content-Type: application/json" \\\n'
  printf '    -d '"'"'{"model": "%s", "messages": [{"role": "user", "content": "Hello"}]}'"'"'\n' \
    "$SUMMARY_MODEL_NAME"
  printf '\n  Note: Run `docker restart litellm` to reload LiteLLM config if needed.\n'
else
  if [ -n "$SUMMARY_CHECKPOINT" ]; then
    printf '\n  Model was NOT registered (eval did not pass).\n'
    printf '  Checkpoint saved at: %s\n' "$SUMMARY_CHECKPOINT"
    printf '  Re-run eval with:\n'
    printf '    scripts/eval-checkpoint.sh %s\n' "$SUMMARY_CHECKPOINT"
  fi
fi

printf '========================================\n\n'

exit 0
