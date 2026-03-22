#!/usr/bin/env bash
set -euo pipefail

# Interactive launcher for karpathy/autoresearch on DGX Spark
# Clones/pulls autoresearch, lets you choose a data source, applies DGX Spark
# tuning, then points you at program.md to start the agent loop.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/spark-config.sh"

AUTORESEARCH_DIR="${HOME}/autoresearch"
AUTORESEARCH_REPO="https://github.com/karpathy/autoresearch.git"

# ============================================================
# 1. Clone or pull latest autoresearch master
# ============================================================
echo ""
echo "========================================"
echo "  autoresearch — DGX Spark Launcher"
echo "========================================"
echo ""

if [ -d "$AUTORESEARCH_DIR/.git" ]; then
  echo "Updating existing autoresearch clone..."
  cd "$AUTORESEARCH_DIR"
  git pull origin master
else
  echo "Cloning karpathy/autoresearch..."
  git clone "$AUTORESEARCH_REPO" "$AUTORESEARCH_DIR"
  cd "$AUTORESEARCH_DIR"
fi

# ============================================================
# 2. Ensure uv is installed
# ============================================================
if ! command -v uv &>/dev/null; then
  echo ""
  echo "uv not found — installing via astral.sh..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

echo ""
echo "Running uv sync..."
cd "$AUTORESEARCH_DIR"
uv sync

# ============================================================
# 3. Data source selection
# ============================================================
echo ""
echo "Select training data source:"
DATA_SOURCE_CHOSEN=""
DATA_SOURCE_LABEL=""

select src in \
  "Default (autoresearch built-in)" \
  "Local directory" \
  "Hugging Face dataset" \
  "GitHub repo" \
  "Kaggle dataset"; do
  case "$src" in
    "Default (autoresearch built-in)")
      DATA_SOURCE_LABEL="default"
      echo ""
      echo "Using autoresearch built-in dataset..."
      uv run prepare.py
      break
      ;;

    "Local directory")
      DATA_SOURCE_LABEL="local"
      echo ""
      read -rp "Path to local data directory: " LOCAL_DATA_PATH
      if [ ! -d "$LOCAL_DATA_PATH" ]; then
        echo "ERROR: Directory not found: $LOCAL_DATA_PATH" >&2
        exit 1
      fi
      echo "Copying .txt and .parquet files from $LOCAL_DATA_PATH into data/..."
      mkdir -p "$AUTORESEARCH_DIR/data"
      find "$LOCAL_DATA_PATH" -maxdepth 2 \( -name "*.txt" -o -name "*.parquet" \) \
        -exec cp {} "$AUTORESEARCH_DIR/data/" \;
      echo "Running prepare.py..."
      uv run prepare.py
      break
      ;;

    "Hugging Face dataset")
      DATA_SOURCE_LABEL="huggingface"
      echo ""
      read -rp "Hugging Face dataset name (e.g. karpathy/climbmix-400b-shuffle): " HF_DATASET
      if [ -z "$HF_DATASET" ]; then
        echo "ERROR: Dataset name cannot be empty." >&2
        exit 1
      fi
      export AUTORESEARCH_HF_DATASET="$HF_DATASET"
      # Try prepare.py first; if it does not consume the env var, fall back to manual download
      echo "Attempting prepare.py with AUTORESEARCH_HF_DATASET=$HF_DATASET..."
      if ! uv run prepare.py 2>&1 | grep -qi "error\|traceback"; then
        echo "prepare.py completed using HF dataset."
      else
        echo "prepare.py does not support custom HF datasets directly."
        echo "Downloading via huggingface-cli into data/..."
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
      echo ""
      read -rp "GitHub repo URL (e.g. https://github.com/user/repo): " GITHUB_URL
      if [ -z "$GITHUB_URL" ]; then
        echo "ERROR: Repo URL cannot be empty." >&2
        exit 1
      fi
      GITHUB_TMP="$(mktemp -d)"
      echo "Cloning $GITHUB_URL into temp dir..."
      git clone --depth=1 "$GITHUB_URL" "$GITHUB_TMP/repo"
      echo "Copying .txt and .parquet files into data/..."
      mkdir -p "$AUTORESEARCH_DIR/data"
      find "$GITHUB_TMP/repo" -maxdepth 4 \( -name "*.txt" -o -name "*.parquet" \) \
        -exec cp {} "$AUTORESEARCH_DIR/data/" \;
      rm -rf "$GITHUB_TMP"
      echo "Running prepare.py..."
      uv run prepare.py
      break
      ;;

    "Kaggle dataset")
      DATA_SOURCE_LABEL="kaggle"
      echo ""
      if ! command -v kaggle &>/dev/null; then
        echo "WARNING: kaggle CLI not installed."
        echo "Install with: pip install kaggle"
        echo "Then add your API token to ~/.kaggle/kaggle.json"
        echo "See: https://www.kaggle.com/docs/api"
        exit 1
      fi
      read -rp "Kaggle dataset identifier (e.g. user/dataset-name): " KAGGLE_ID
      if [ -z "$KAGGLE_ID" ]; then
        echo "ERROR: Dataset identifier cannot be empty." >&2
        exit 1
      fi
      mkdir -p "$AUTORESEARCH_DIR/data"
      echo "Downloading Kaggle dataset $KAGGLE_ID..."
      kaggle datasets download -d "$KAGGLE_ID" -p "$AUTORESEARCH_DIR/data/" --unzip
      echo "Running prepare.py..."
      uv run prepare.py
      break
      ;;

    *)
      echo "Invalid option — please enter a number between 1 and 5."
      ;;
  esac
done

# ============================================================
# 4. Validate tokenizer output exists before continuing
# ============================================================
echo ""
echo "Validating tokenizer output..."
TOKENIZER_OK=0
for token_file in "$AUTORESEARCH_DIR/data/train.bin" \
                  "$AUTORESEARCH_DIR/data/val.bin" \
                  "$AUTORESEARCH_DIR/train_tokens.bin" \
                  "$AUTORESEARCH_DIR/val_tokens.bin"; do
  if [ -f "$token_file" ]; then
    echo "  Found: $token_file"
    TOKENIZER_OK=1
  fi
done
# Also accept any .bin file in data/
if [ "$TOKENIZER_OK" -eq 0 ]; then
  if find "$AUTORESEARCH_DIR" -maxdepth 2 -name "*.bin" | grep -q .; then
    echo "  Found token .bin files in $AUTORESEARCH_DIR"
    TOKENIZER_OK=1
  fi
fi
if [ "$TOKENIZER_OK" -eq 0 ]; then
  echo "WARNING: No tokenizer output (.bin) found. prepare.py may have failed." >&2
  echo "Check output above. Continuing anyway..." >&2
fi

# ============================================================
# 5. Apply DGX Spark GPU tuning
# ============================================================
echo ""
echo "Applying DGX Spark tuning overrides..."
apply_spark_config "$AUTORESEARCH_DIR/train.py"
apply_spark_timing "$AUTORESEARCH_DIR/train.py"

# ============================================================
# 6. Print launch banner
# ============================================================
echo ""
echo "========================================"
echo "  autoresearch — Ready"
echo "========================================"
echo ""
echo "  Repo dir:    $AUTORESEARCH_DIR"
echo "  Data source: $DATA_SOURCE_LABEL"
echo "  GPU tuning:  DGX Spark (128 Blackwell cores)"
echo "    - DEPTH           = $SPARK_DEPTH"
echo "    - TOTAL_BATCH_SIZE= $SPARK_TOTAL_BATCH_SIZE"
echo "    - MAX_SEQ_LEN     = $SPARK_MAX_SEQ_LEN"
echo "    - TRAIN_MINUTES   = $SPARK_TRAIN_MINUTES"
echo "    - EVAL_TOKENS     = $SPARK_EVAL_TOKENS"
echo ""
echo "  Estimated per-experiment duration: ~${SPARK_TRAIN_MINUTES} min (training) + eval"
echo ""
echo "========================================"
echo ""
echo "Point your AI agent at:"
echo "  $AUTORESEARCH_DIR/program.md"
echo ""
echo "Example Claude CLI:"
echo "  claude --file $AUTORESEARCH_DIR/program.md"
echo ""

# ============================================================
# 7. Optional: run one test experiment to validate setup
# ============================================================
read -rp "Run a single test experiment now to validate setup? [y/N] " RUN_TEST
if [[ "$RUN_TEST" =~ ^[Yy]$ ]]; then
  echo ""
  echo "Running test experiment: uv run train.py"
  echo "(Ctrl+C to abort)"
  echo ""
  cd "$AUTORESEARCH_DIR"
  uv run train.py
  echo ""
  echo "Test experiment complete."
fi

echo ""
echo "Setup complete. Happy researching!"
