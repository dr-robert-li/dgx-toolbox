---
phase: quick
plan: 260322-m8z
subsystem: karpathy-autoresearch
tags: [autoresearch, launcher, dgx-spark, gpu-tuning, bash]
dependency_graph:
  requires: []
  provides: [karpathy-autoresearch launcher, DGX Spark GPU config, autoresearch aliases]
  affects: [example.bash_aliases]
tech_stack:
  added: [karpathy/autoresearch, uv, huggingface-cli, kaggle-cli]
  patterns: [source-library pattern, env-var headless mode, sed-based config patching]
key_files:
  created:
    - karpathy-autoresearch/spark-config.sh
    - karpathy-autoresearch/launch-autoresearch.sh
    - karpathy-autoresearch/launch-autoresearch-sync.sh
    - karpathy-autoresearch/README.md
  modified:
    - example.bash_aliases
decisions:
  - AUTORESEARCH_DIR set to ~/autoresearch (outside dgx-toolbox) so git-managed toolbox and research clones do not conflict
  - HuggingFace source tries prepare.py with env var first, falls back to huggingface-cli download on failure
  - Idempotent sed patching via comment suffix (DGX Spark override) prevents double-patching on re-run
metrics:
  duration: ~8 minutes
  completed_date: "2026-03-22"
  tasks_completed: 2
  files_created: 4
  files_modified: 1
---

# Quick Task 260322-m8z: autoresearch launcher with DGX Spark tuning — Summary

**One-liner:** Interactive + headless launchers for karpathy/autoresearch with sed-based parameter scaling for 128 Blackwell CUDA cores (DEPTH=4, SEQ_LEN=256, BATCH=4, 10min experiments).

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Create DGX Spark config and launcher scripts | 8ae2c42 | spark-config.sh, launch-autoresearch.sh, launch-autoresearch-sync.sh |
| 2 | Add aliases and README | 5a8bb7e | example.bash_aliases, README.md |

## What Was Built

### spark-config.sh
Declares DGX Spark tuning constants and two functions:
- `apply_spark_config(train_py)` — sed-patches DEPTH, TOTAL_BATCH_SIZE, DEVICE_BATCH_SIZE, GRAD_ACCUM in train.py, and MAX_SEQ_LEN, EVAL_TOKENS in prepare.py. Idempotent via comment suffix. Prints each change.
- `apply_spark_timing(train_py)` — patches the 5-minute wall-clock timer (MAX_TIME pattern) to SPARK_TRAIN_MINUTES=10.

### launch-autoresearch.sh (interactive)
1. Sources lib.sh + spark-config.sh
2. Clones or pulls `https://github.com/karpathy/autoresearch.git` into `~/autoresearch/`
3. Installs uv if missing, runs `uv sync`
4. Interactive `select` menu for 5 data sources: default, local, huggingface, github, kaggle
5. Validates tokenizer output (.bin files) after prepare.py
6. Calls `apply_spark_config` + `apply_spark_timing`
7. Prints summary banner with all tuning values
8. Prints program.md path and example `claude --file` command
9. Optionally runs single test experiment

### launch-autoresearch-sync.sh (headless)
Same flow but reads `AUTORESEARCH_DATA_SOURCE`, `AUTORESEARCH_DATA_PATH`, `AUTORESEARCH_SKIP_TUNE`, `AUTORESEARCH_RUN_TEST` env vars. No interactive prompts. Suitable for NVIDIA Sync sessions and CI/cron.

### example.bash_aliases
Added "--- Autonomous Research ---" section between Fine-Tuning and GPU Containers:
- `autoresearch` → interactive launcher
- `autoresearch-stop` → pkill uv run train.py

### README.md
Documents: autoresearch overview, DGX Spark tuning rationale table, all 5 data source options with interactive + headless examples, ngc-jupyter integration for result analysis, customization guide.

## Deviations from Plan

None — plan executed exactly as written.

## Self-Check

Checking files exist and commits are present...

## Self-Check: PASSED

All 5 files confirmed on disk. Both commits (8ae2c42, 5a8bb7e) confirmed in git log.
