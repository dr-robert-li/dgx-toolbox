---
phase: quick/260322-m8z
verified: 2026-03-22T16:10:00Z
status: passed
score: 6/6 must-haves verified
re_verification: false
gaps: []
human_verification:
  - test: "Run autoresearch interactively and select each data source option"
    expected: "Each menu choice executes the correct data flow and prepare.py completes"
    why_human: "Requires active network, Kaggle credentials, and HuggingFace token — cannot verify data flows without live autoresearch repo"
  - test: "Run autoresearch-sync.sh with AUTORESEARCH_DATA_SOURCE=huggingface"
    expected: "No prompts, reads env vars, downloads dataset, applies spark tuning, exits cleanly"
    why_human: "Headless env-var flow requires network and HuggingFace CLI in PATH"
---

# Quick Task 260322-m8z: autoresearch launcher with DGX Spark tuning — Verification Report

**Task Goal:** Create a launcher script and configuration for karpathy/autoresearch in ./karpathy-autoresearch/ that pulls the latest master commit, tunes training parameters for 128 Blackwell CUDA cores on a DGX Spark, allows user to self-select training data source (local, HuggingFace, GitHub, Kaggle), and points the agent at program.md to start training.
**Verified:** 2026-03-22T16:10:00Z
**Status:** PASSED
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | User can launch autoresearch with a single command (alias or script) | VERIFIED | `alias autoresearch='~/dgx-toolbox/karpathy-autoresearch/launch-autoresearch.sh'` at example.bash_aliases:21 |
| 2 | Launcher clones/pulls latest autoresearch master before each run | VERIFIED | launch-autoresearch.sh:24-32 — git clone/pull logic present; same in sync script:40-48 |
| 3 | User is prompted to select data source (local, HuggingFace, GitHub, Kaggle) before prepare.py | VERIFIED | launch-autoresearch.sh:57-162 — `select src in` menu with all 5 options, each running prepare.py |
| 4 | Training parameters are automatically tuned for DGX Spark 128 CUDA core Blackwell GPU | VERIFIED | spark-config.sh:29-109 implements `apply_spark_config()` with sed patches for DEPTH=4, TOTAL_BATCH_SIZE=4, MAX_SEQ_LEN=256, EVAL_TOKENS=100000; called at launch-autoresearch.sh:196-197 |
| 5 | Launcher works headless via sync mode (no interactive prompts, uses env vars) | VERIFIED | launch-autoresearch-sync.sh:26-29 reads AUTORESEARCH_DATA_SOURCE, AUTORESEARCH_DATA_PATH, AUTORESEARCH_SKIP_TUNE, AUTORESEARCH_RUN_TEST; case statement at :68-143 handles all 5 sources without prompts |
| 6 | Agent loop starts by pointing at program.md after data prep completes | VERIFIED | launch-autoresearch.sh:221-224 prints `$AUTORESEARCH_DIR/program.md` and example `claude --file` command; sync script:168-169 prints same |

**Score:** 6/6 truths verified

### Required Artifacts

| Artifact | Min Lines | Actual Lines | Status | Details |
|----------|-----------|--------------|--------|---------|
| `karpathy-autoresearch/launch-autoresearch.sh` | 80 | 243 | VERIFIED | Interactive launcher with 5-option data source menu, uv install check, spark tuning, banner, optional test run. chmod 775. |
| `karpathy-autoresearch/launch-autoresearch-sync.sh` | 30 | 169 | VERIFIED | Headless env-var launcher, all 5 data source cases, SKIP_TUNE and RUN_TEST support, program.md pointer at end. chmod 775. |
| `karpathy-autoresearch/spark-config.sh` | 20 | 149 | VERIFIED | 8 SPARK_ constants, `apply_spark_config()` (sed patches for 6 params in train.py + prepare.py), `apply_spark_timing()` (wall-clock timer patch). chmod 775. Idempotent via comment suffix. |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `launch-autoresearch.sh` | `spark-config.sh` | `source spark-config.sh` | WIRED | launch-autoresearch.sh:10 — `source "$SCRIPT_DIR/spark-config.sh"` |
| `launch-autoresearch-sync.sh` | `spark-config.sh` | `source spark-config.sh` | WIRED | launch-autoresearch-sync.sh:20 — `source "$SCRIPT_DIR/spark-config.sh"` |
| `launch-autoresearch.sh` | `https://github.com/karpathy/autoresearch` | `git clone/pull` | WIRED | launch-autoresearch.sh:27,30 — `git pull origin master` and `git clone "$AUTORESEARCH_REPO"` |
| `example.bash_aliases` | `karpathy-autoresearch/launch-autoresearch.sh` | `alias autoresearch=` | WIRED | example.bash_aliases:21 — `alias autoresearch='~/dgx-toolbox/karpathy-autoresearch/launch-autoresearch.sh'` |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `launch-autoresearch.sh` | 100 | HuggingFace fallback detection uses `grep -qi "error\|traceback"` on stdout — `prepare.py` may succeed silently or fail without printing those words | Warning | HF dataset detection could misclassify success/failure; both paths run prepare.py so worst case is duplicate execution |

No TODO/FIXME/placeholder comments found. No stub return values. No empty handlers.

### Human Verification Required

#### 1. Interactive data source menu — all 5 branches

**Test:** Run `autoresearch` alias, select each of the 5 options in turn.
**Expected:** Default runs prepare.py directly; Local prompts for path and copies files; HuggingFace prompts for dataset name and downloads; GitHub prompts for repo URL and clones; Kaggle checks for kaggle CLI and downloads.
**Why human:** Requires live network access to github.com/karpathy/autoresearch, HuggingFace, and optional Kaggle credentials.

#### 2. Headless sync mode with env vars

**Test:** Set `AUTORESEARCH_DATA_SOURCE=default` and run `launch-autoresearch-sync.sh`.
**Expected:** No prompts; all output prefixed with `[sync]`; program.md path printed at end.
**Why human:** Requires live network to clone autoresearch repo and run uv sync; cannot verify without real environment.

#### 3. Spark tuning actually reduces training resource usage

**Test:** Run `uv run train.py` after apply_spark_config and compare GPU memory usage against untuned run.
**Expected:** Training completes in ~10 minutes; GPU VRAM stays within DGX Spark limits.
**Why human:** Requires physical DGX Spark hardware with 128 Blackwell CUDA cores to measure actual memory/timing.

### Commit Verification

Both commits claimed in SUMMARY.md confirmed in git log:
- `8ae2c42` — feat(260322-m8z): create DGX Spark config and autoresearch launcher scripts
- `5a8bb7e` — feat(260322-m8z): add aliases and README for autoresearch launcher

### Gaps Summary

No gaps. All six observable truths pass automated verification. All three required artifacts exist, exceed minimum line counts, contain substantive implementations (no stubs), are wired to each other via `source`, and are marked executable (chmod 775). The `alias autoresearch=` key link is confirmed in example.bash_aliases at the correct location (between Fine-Tuning and GPU Containers sections).

The one warning — the HuggingFace fallback detection heuristic — does not block the goal. Both branches of the HF conditional call prepare.py, so data prep completes regardless.

---

_Verified: 2026-03-22T16:10:00Z_
_Verifier: Claude (gsd-verifier)_
