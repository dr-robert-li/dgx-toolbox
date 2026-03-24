---
phase: 12-demo-and-documentation
plan: "01"
subsystem: demo-and-documentation
tags: [demo, documentation, autoresearch, pipeline, bash]
dependency_graph:
  requires: [11-pipeline-wiring]
  provides: [DEMO-01, DEMO-02]
  affects: [scripts/demo-autoresearch.sh, README.md, CHANGELOG.md, example.bash_aliases]
tech_stack:
  added: []
  patterns: [bash-demo-orchestrator, cycle-monitor-background-job, tee-logging]
key_files:
  created:
    - scripts/demo-autoresearch.sh
  modified:
    - README.md
    - CHANGELOG.md
    - example.bash_aliases
decisions:
  - Cycle-limiting via background log monitor (grep on "Cycle N" pattern) plus time-based fallback (DEMO_CYCLES * SPARK_TRAIN_MINUTES * 60 + 60s buffer) — avoids patching autoresearch train.py with max_cycles support
  - HARNESS_URL probe uses /health then / then /probe fallback chain to handle different harness versions
  - Training PID tracked via jobs -p after pipe (not ${PIPESTATUS[0]}) for reliable background process capture
metrics:
  duration: 200s
  completed_date: "2026-03-24"
  tasks_completed: 2
  tasks_total: 2
  files_created: 1
  files_modified: 3
---

# Phase 12 Plan 01: Demo and Documentation Summary

**One-liner:** End-to-end autoresearch demo script with 7-section pipeline orchestration (data source menu, safety screening, Spark tuning, cycle-limited training, eval-checkpoint integration) plus README walkthrough and v1.2 CHANGELOG entry.

## What Was Built

### Task 1: scripts/demo-autoresearch.sh

Bash script that orchestrates the full autoresearch pipeline in 7 clearly labeled sections:

1. **Prerequisites** — Checks/clones autoresearch repo, installs uv, runs uv sync, probes harness reachability and vLLM/Ollama status
2. **Data source selection** — Replicates the 6-option select menu from launch-autoresearch.sh (default, local dir, HuggingFace, GitHub, Kaggle, auto-discovered datasets), runs prepare.py after selection
3. **Optional screening** — Offers `screen-data.sh` screening if harness is reachable and HARNESS_API_KEY is available; gracefully skips if not
4. **DGX Spark tuning** — Calls `apply_spark_config` and `apply_spark_timing` from spark-config.sh on the cloned train.py
5. **Training** — Runs `uv run train.py` in background, tees to terminal and `demo-training.log`, uses a background cycle monitor that greps the log for completion patterns and sends SIGTERM after `DEMO_CYCLES` iterations
6. **Safety eval** — Finds the latest HF-format checkpoint (most recent dir with config.json), calls `eval-checkpoint.sh`, parses `safety-eval.json` for pass/fail/F1
7. **Summary** — Prints a formatted block with dataset, cycles, screening, eval result, and copy-pasteable curl command (omitted if eval failed)

Key design decisions:
- Exit trap kills background training process on any exit
- Both cycle-count monitor and time-based fallback (DEMO_CYCLES * SPARK_TRAIN_MINUTES * 60 + 60s) prevent runaway training
- Script exits 0 even if eval fails (non-destructive by design)

### Task 2: README.md, CHANGELOG.md, example.bash_aliases

**README.md:** Inserted `### Autoresearch Pipeline (Data to Inference)` section after the Autonomous Research subsection and before `## Safety Harness`. Section includes:
- Overview paragraph
- Quick start with `demo-autoresearch` alias and `DEMO_CYCLES=5` override example
- 5-stage pipeline walkthrough with expected output for each stage
- Manual pipeline commands for running stages individually
- Troubleshooting table (5 common problems)
- No-GPU fallback note for testing eval/registration without training

**CHANGELOG.md:** Added `## 2026-03-24 — Autoresearch Integration (v1.2)` entry at the top of the file, covering all 7 autoresearch integration items from Phase 11-12.

**example.bash_aliases:** Added `demo-autoresearch` alias after the existing autoresearch aliases.

## Deviations from Plan

### Auto-fixed Issues

None — plan executed exactly as written.

**Note on implementation approach:** The plan suggested using a cycle-limiting background monitor because autoresearch may not natively support `max_cycles`. The implementation uses exactly that pattern: a `_monitor_cycles()` function runs in background, polls the log file for completion patterns, and sends SIGTERM after DEMO_CYCLES iterations. A time-based fallback was added as an additional safety net.

## Decisions Made

1. **Cycle monitor uses grep on log patterns** — `grep -cE "(Cycle [0-9]+ complete|step [0-9]+.*loss|experiment [0-9]+)"` catches the most common autoresearch output patterns without requiring knowledge of the exact format
2. **Harness probe chain** — `/health` → `/` → `/probe` with `--max-time 5` to be resilient across harness versions
3. **Checkpoint search** — Scans `experiments/`, `out/`, `checkpoints/`, and the autoresearch root for directories containing `config.json`, sorted by mtime — covers all common autoresearch output layouts

## Self-Check: PASSED

| Item | Status |
|------|--------|
| `scripts/demo-autoresearch.sh` created | FOUND |
| `12-01-SUMMARY.md` created | FOUND |
| Task 1 commit `669884f` | FOUND |
| Task 2 commit `26325af` | FOUND |
