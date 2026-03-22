#!/usr/bin/env bash
set -euo pipefail

# Headless sync-mode launcher for karpathy/autoresearch on DGX Spark.
# No interactive prompts — all configuration via environment variables.
#
# Environment variables:
#   AUTORESEARCH_DATA_SOURCE  — one of: default, local, huggingface, github, kaggle
#   AUTORESEARCH_DATA_PATH    — path/name/URL for the selected source
#   AUTORESEARCH_SKIP_TUNE    — set to "1" to skip DGX Spark parameter tuning
#   AUTORESEARCH_RUN_TEST     — set to "1" to run one test experiment after setup
#
# Example (HuggingFace):
#   AUTORESEARCH_DATA_SOURCE=huggingface \
#   AUTORESEARCH_DATA_PATH=karpathy/climbmix-400b-shuffle \
#   ~/dgx-toolbox/karpathy-autoresearch/launch-autoresearch-sync.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/spark-config.sh"

AUTORESEARCH_DIR="${HOME}/autoresearch"
AUTORESEARCH_REPO="https://github.com/karpathy/autoresearch.git"

# Defaults for env vars
AUTORESEARCH_DATA_SOURCE="${AUTORESEARCH_DATA_SOURCE:-default}"
AUTORESEARCH_DATA_PATH="${AUTORESEARCH_DATA_PATH:-}"
AUTORESEARCH_SKIP_TUNE="${AUTORESEARCH_SKIP_TUNE:-0}"
AUTORESEARCH_RUN_TEST="${AUTORESEARCH_RUN_TEST:-0}"

echo "[sync] autoresearch sync-mode launcher starting"
echo "[sync] DATA_SOURCE=$AUTORESEARCH_DATA_SOURCE"
echo "[sync] SKIP_TUNE=$AUTORESEARCH_SKIP_TUNE"
echo "[sync] RUN_TEST=$AUTORESEARCH_RUN_TEST"
echo ""

# ============================================================
# 1. Clone or pull latest master
# ============================================================
if [ -d "$AUTORESEARCH_DIR/.git" ]; then
  echo "[sync] Pulling latest master..."
  cd "$AUTORESEARCH_DIR"
  git pull origin master
else
  echo "[sync] Cloning karpathy/autoresearch..."
  git clone "$AUTORESEARCH_REPO" "$AUTORESEARCH_DIR"
  cd "$AUTORESEARCH_DIR"
fi

# ============================================================
# 2. Ensure uv is installed
# ============================================================
if ! command -v uv &>/dev/null; then
  echo "[sync] Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

echo "[sync] Running uv sync..."
cd "$AUTORESEARCH_DIR"
uv sync

# ============================================================
# 3. Data source handling (env-var driven, no prompts)
# ============================================================
echo "[sync] Setting up data source: $AUTORESEARCH_DATA_SOURCE"

case "$AUTORESEARCH_DATA_SOURCE" in
  default)
    echo "[sync] Running prepare.py with built-in dataset..."
    uv run prepare.py
    ;;

  local)
    if [ -z "$AUTORESEARCH_DATA_PATH" ]; then
      echo "[sync] ERROR: AUTORESEARCH_DATA_PATH must be set for source=local" >&2
      exit 1
    fi
    if [ ! -d "$AUTORESEARCH_DATA_PATH" ]; then
      echo "[sync] ERROR: Local path not found: $AUTORESEARCH_DATA_PATH" >&2
      exit 1
    fi
    echo "[sync] Copying files from $AUTORESEARCH_DATA_PATH..."
    mkdir -p "$AUTORESEARCH_DIR/data"
    find "$AUTORESEARCH_DATA_PATH" -maxdepth 2 \( -name "*.txt" -o -name "*.parquet" \) \
      -exec cp {} "$AUTORESEARCH_DIR/data/" \;
    echo "[sync] Running prepare.py..."
    uv run prepare.py
    ;;

  huggingface)
    if [ -z "$AUTORESEARCH_DATA_PATH" ]; then
      echo "[sync] ERROR: AUTORESEARCH_DATA_PATH must be set for source=huggingface" >&2
      exit 1
    fi
    export AUTORESEARCH_HF_DATASET="$AUTORESEARCH_DATA_PATH"
    echo "[sync] Downloading HuggingFace dataset: $AUTORESEARCH_DATA_PATH"
    mkdir -p "$AUTORESEARCH_DIR/data"
    uv run -- huggingface-cli download "$AUTORESEARCH_DATA_PATH" \
      --local-dir "$AUTORESEARCH_DIR/data/" \
      --repo-type dataset
    echo "[sync] Running prepare.py..."
    uv run prepare.py
    ;;

  github)
    if [ -z "$AUTORESEARCH_DATA_PATH" ]; then
      echo "[sync] ERROR: AUTORESEARCH_DATA_PATH must be set for source=github" >&2
      exit 1
    fi
    GITHUB_TMP="$(mktemp -d)"
    echo "[sync] Cloning $AUTORESEARCH_DATA_PATH..."
    git clone --depth=1 "$AUTORESEARCH_DATA_PATH" "$GITHUB_TMP/repo"
    mkdir -p "$AUTORESEARCH_DIR/data"
    find "$GITHUB_TMP/repo" -maxdepth 4 \( -name "*.txt" -o -name "*.parquet" \) \
      -exec cp {} "$AUTORESEARCH_DIR/data/" \;
    rm -rf "$GITHUB_TMP"
    echo "[sync] Running prepare.py..."
    uv run prepare.py
    ;;

  kaggle)
    if [ -z "$AUTORESEARCH_DATA_PATH" ]; then
      echo "[sync] ERROR: AUTORESEARCH_DATA_PATH must be set for source=kaggle" >&2
      exit 1
    fi
    if ! command -v kaggle &>/dev/null; then
      echo "[sync] ERROR: kaggle CLI not installed. Run: pip install kaggle" >&2
      exit 1
    fi
    mkdir -p "$AUTORESEARCH_DIR/data"
    echo "[sync] Downloading Kaggle dataset: $AUTORESEARCH_DATA_PATH"
    kaggle datasets download -d "$AUTORESEARCH_DATA_PATH" -p "$AUTORESEARCH_DIR/data/" --unzip
    echo "[sync] Running prepare.py..."
    uv run prepare.py
    ;;

  *)
    echo "[sync] ERROR: Unknown AUTORESEARCH_DATA_SOURCE='$AUTORESEARCH_DATA_SOURCE'" >&2
    echo "[sync] Valid values: default, local, huggingface, github, kaggle" >&2
    exit 1
    ;;
esac

# ============================================================
# 4. Apply DGX Spark tuning (unless skipped)
# ============================================================
if [ "$AUTORESEARCH_SKIP_TUNE" = "1" ]; then
  echo "[sync] Skipping DGX Spark tuning (AUTORESEARCH_SKIP_TUNE=1)"
else
  echo "[sync] Applying DGX Spark tuning overrides..."
  apply_spark_config "$AUTORESEARCH_DIR/train.py"
  apply_spark_timing "$AUTORESEARCH_DIR/train.py"
fi

# ============================================================
# 5. Optional test experiment
# ============================================================
if [ "$AUTORESEARCH_RUN_TEST" = "1" ]; then
  echo "[sync] Running test experiment: uv run train.py"
  cd "$AUTORESEARCH_DIR"
  uv run train.py
  echo "[sync] Test experiment complete."
fi

echo ""
echo "[sync] Setup complete."
echo "[sync] Agent instructions: $AUTORESEARCH_DIR/program.md"
echo "[sync] To start agent loop, point Claude/agent at program.md"
