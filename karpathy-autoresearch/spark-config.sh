#!/usr/bin/env bash
# DGX Spark tuning for NVIDIA Blackwell GB10 GPU
#
# Hardware specs:
#   CUDA Cores:   6,144
#   Tensor Cores: 192 (5th Generation)
#   RT Cores:     48 (4th Generation)
#   Architecture: NVIDIA Blackwell (GB10)
#   Memory:       128 GB unified LPDDR5x
#
# H100 comparison: 16,896 CUDA cores / 80 GB HBM3 — Spark has ~36% of H100 CUDA
# cores but 60% more memory (unified). Memory-bound workloads benefit; compute-bound
# workloads need reduced parallelism.
#
# These overrides are applied via sed to train.py/prepare.py after clone/pull.

# --- Model Architecture ---
SPARK_DEPTH=8              # Keep default depth — 128 GB unified memory can hold full model
SPARK_TOTAL_BATCH_SIZE=16384  # In tokens (must be divisible by DEVICE_BATCH_SIZE * MAX_SEQ_LEN * num_gpus)
SPARK_DEVICE_BATCH_SIZE=4  # 128 GB unified memory supports reasonable micro-batches

# --- Sequence Length ---
SPARK_MAX_SEQ_LEN=512      # Moderate reduction — memory is plentiful but compute is the bottleneck

# --- Training Duration ---
SPARK_TRAIN_MINUTES=8      # Slight increase from 5min — ~36% of H100 compute

# --- Learning Rate ---
SPARK_LR_SCALE=0.7         # Moderate scaling — larger batches than before, less aggressive reduction

# --- Gradient Accumulation ---
SPARK_GRAD_ACCUM=4         # Less accumulation needed with larger device batch size

# --- Eval ---
SPARK_EVAL_TOKENS=250000   # Moderate eval — memory supports it, compute is the constraint

# Apply DGX Spark parameter overrides to train.py and prepare.py
# Usage: apply_spark_config <train_py_path>
# Safe to call multiple times (idempotent sed replacements).
apply_spark_config() {
  local train_py="$1"
  local prepare_py
  prepare_py="$(dirname "$train_py")/prepare.py"

  if [ ! -f "$train_py" ]; then
    echo "ERROR: train.py not found at $train_py" >&2
    return 1
  fi

  echo ""
  echo "--- Applying DGX Spark tuning to $(basename "$train_py") ---"

  # DEPTH — match lines like: DEPTH = 12
  if grep -qE "^DEPTH\s*=" "$train_py"; then
    local old_depth
    old_depth=$(grep -E "^DEPTH\s*=" "$train_py" | head -1 | sed 's/.*=\s*//' | tr -d ' ')
    sed -i "s/^DEPTH\s*=.*/DEPTH = ${SPARK_DEPTH}  # DGX Spark override (was ${old_depth})/" "$train_py"
    echo "  DEPTH: ${old_depth} -> ${SPARK_DEPTH}"
  else
    echo "  DEPTH: not found in train.py (skipped)"
  fi

  # TOTAL_BATCH_SIZE — match lines like: TOTAL_BATCH_SIZE = 32
  if grep -qE "^TOTAL_BATCH_SIZE\s*=" "$train_py"; then
    local old_tbs
    old_tbs=$(grep -E "^TOTAL_BATCH_SIZE\s*=" "$train_py" | head -1 | sed 's/.*=\s*//' | tr -d ' ')
    sed -i "s/^TOTAL_BATCH_SIZE\s*=.*/TOTAL_BATCH_SIZE = ${SPARK_TOTAL_BATCH_SIZE}  # DGX Spark override (was ${old_tbs})/" "$train_py"
    echo "  TOTAL_BATCH_SIZE: ${old_tbs} -> ${SPARK_TOTAL_BATCH_SIZE}"
  else
    echo "  TOTAL_BATCH_SIZE: not found in train.py (skipped)"
  fi

  # DEVICE_BATCH_SIZE in train.py — match lines like: DEVICE_BATCH_SIZE = 128
  if grep -qE "^DEVICE_BATCH_SIZE\s*=" "$train_py"; then
    local old_dbs_train
    old_dbs_train=$(grep -E "^DEVICE_BATCH_SIZE\s*=" "$train_py" | head -1 | sed 's/.*=\s*//' | tr -d ' ')
    sed -i "s/^DEVICE_BATCH_SIZE\s*=.*/DEVICE_BATCH_SIZE = ${SPARK_DEVICE_BATCH_SIZE}  # DGX Spark override/" "$train_py"
    echo "  DEVICE_BATCH_SIZE: ${old_dbs_train} -> ${SPARK_DEVICE_BATCH_SIZE}"
  else
    echo "  DEVICE_BATCH_SIZE: not found in train.py (skipped)"
  fi

  # Patch gradient accumulation if present
  if grep -qE "^GRAD_ACCUM\s*=" "$train_py"; then
    local old_ga
    old_ga=$(grep -E "^GRAD_ACCUM\s*=" "$train_py" | head -1 | sed 's/.*=\s*//' | tr -d ' ')
    sed -i "s/^GRAD_ACCUM\s*=.*/GRAD_ACCUM = ${SPARK_GRAD_ACCUM}  # DGX Spark override (was ${old_ga})/" "$train_py"
    echo "  GRAD_ACCUM: ${old_ga} -> ${SPARK_GRAD_ACCUM}"
  fi

  # Patch prepare.py constants if file exists
  if [ -f "$prepare_py" ]; then
    echo ""
    echo "--- Applying DGX Spark tuning to $(basename "$prepare_py") ---"

    # MAX_SEQ_LEN
    if grep -qE "^MAX_SEQ_LEN\s*=" "$prepare_py"; then
      local old_msl
      old_msl=$(grep -E "^MAX_SEQ_LEN\s*=" "$prepare_py" | head -1 | sed 's/.*=\s*//' | tr -d ' ')
      sed -i "s/^MAX_SEQ_LEN\s*=.*/MAX_SEQ_LEN = ${SPARK_MAX_SEQ_LEN}  # DGX Spark override (was ${old_msl})/" "$prepare_py"
      echo "  MAX_SEQ_LEN: ${old_msl} -> ${SPARK_MAX_SEQ_LEN}"
    else
      echo "  MAX_SEQ_LEN: not found in prepare.py (skipped)"
    fi

    # DEVICE_BATCH_SIZE
    if grep -qE "^DEVICE_BATCH_SIZE\s*=" "$prepare_py"; then
      local old_dbs
      old_dbs=$(grep -E "^DEVICE_BATCH_SIZE\s*=" "$prepare_py" | head -1 | sed 's/.*=\s*//' | tr -d ' ')
      sed -i "s/^DEVICE_BATCH_SIZE\s*=.*/DEVICE_BATCH_SIZE = ${SPARK_DEVICE_BATCH_SIZE}  # DGX Spark override (was ${old_dbs})/" "$prepare_py"
      echo "  DEVICE_BATCH_SIZE: ${old_dbs} -> ${SPARK_DEVICE_BATCH_SIZE}"
    else
      echo "  DEVICE_BATCH_SIZE: not found in prepare.py (skipped)"
    fi

    # EVAL_TOKENS
    if grep -qE "^EVAL_TOKENS\s*=" "$prepare_py"; then
      local old_et
      old_et=$(grep -E "^EVAL_TOKENS\s*=" "$prepare_py" | head -1 | sed 's/.*=\s*//' | tr -d ' ')
      sed -i "s/^EVAL_TOKENS\s*=.*/EVAL_TOKENS = ${SPARK_EVAL_TOKENS}  # DGX Spark override (was ${old_et})/" "$prepare_py"
      echo "  EVAL_TOKENS: ${old_et} -> ${SPARK_EVAL_TOKENS}"
    else
      echo "  EVAL_TOKENS: not found in prepare.py (skipped)"
    fi
  else
    echo "  prepare.py not found at $prepare_py (skipped)"
  fi

  echo ""
}

# Apply the 5-minute wall-clock timer override in train.py
# Replaces the hardcoded duration (e.g. 5 * 60) with SPARK_TRAIN_MINUTES * 60
# Usage: apply_spark_timing <train_py_path>
apply_spark_timing() {
  local train_py="$1"

  if [ ! -f "$train_py" ]; then
    echo "ERROR: train.py not found at $train_py" >&2
    return 1
  fi

  echo "--- Applying DGX Spark timing to $(basename "$train_py") ---"

  # Common patterns for wall-clock limit in autoresearch train.py:
  # MAX_TIME = 5 * 60  or  max_time = 5 * 60  or  TRAIN_MINUTES = 5
  local patched=0

  if grep -qE "MAX_TIME\s*=\s*[0-9]+\s*\*\s*60" "$train_py"; then
    local old_val
    old_val=$(grep -E "MAX_TIME\s*=\s*[0-9]+\s*\*\s*60" "$train_py" | head -1 | sed 's/.*=\s*//' | tr -d ' ')
    sed -i "s/MAX_TIME\s*=\s*[0-9]*\s*\*\s*60/MAX_TIME = ${SPARK_TRAIN_MINUTES} * 60  # DGX Spark override/" "$train_py"
    echo "  MAX_TIME: ${old_val} -> ${SPARK_TRAIN_MINUTES} * 60"
    patched=1
  fi

  if grep -qE "^TRAIN_MINUTES\s*=" "$train_py"; then
    local old_tm
    old_tm=$(grep -E "^TRAIN_MINUTES\s*=" "$train_py" | head -1 | sed 's/.*=\s*//' | tr -d ' ')
    sed -i "s/^TRAIN_MINUTES\s*=.*/TRAIN_MINUTES = ${SPARK_TRAIN_MINUTES}  # DGX Spark override (was ${old_tm})/" "$train_py"
    echo "  TRAIN_MINUTES: ${old_tm} -> ${SPARK_TRAIN_MINUTES}"
    patched=1
  fi

  if [ "$patched" -eq 0 ]; then
    echo "  No wall-clock timer pattern found in train.py (manual check recommended)"
  fi

  echo ""
}
