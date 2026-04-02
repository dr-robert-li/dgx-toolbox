---
phase: quick
plan: 260403-cx2
subsystem: base-toolbox
tags: [docker, ml-deps, keras-conflict, transformers]
dependency_graph:
  requires: []
  provides: [base-toolbox ML training stack]
  affects: [eval-toolbox, data-toolbox, unsloth-headless]
tech_stack:
  added: [transformers, accelerate, peft, trl, sentencepiece, hf_transfer, pyyaml]
  patterns: [keras conflict removal via pip uninstall before install]
key_files:
  created: []
  modified:
    - base-toolbox/Dockerfile
decisions:
  - "keras-nlp/keras/keras-core uninstalled before transformers install — NGC PyTorch 26.02 ships keras_nlp stub that conflicts with transformers 4.56+"
  - "No version pins added — pip resolves compatible versions against NGC base image"
  - "ML deps grouped with comment in single pip install block for readability"
metrics:
  duration: "5 minutes"
  completed_date: "2026-04-03"
  tasks_completed: 1
  tasks_total: 1
  files_modified: 1
---

# Quick Task 260403-cx2: Fix Base-Toolbox Dockerfile to Include ML Training Deps

**One-liner:** Added keras_nlp conflict removal and 7 ML training packages (transformers, trl, peft, accelerate, sentencepiece, hf_transfer, pyyaml) to base-toolbox Dockerfile so all downstream images inherit a working ML stack.

## What Was Done

Added two changes to `base-toolbox/Dockerfile`:

1. A new `RUN pip uninstall -y keras-nlp keras keras-core 2>/dev/null || true` layer placed BEFORE the pip install block. The NGC PyTorch 26.02 base ships a keras_nlp stub that conflicts with transformers 4.56+; removing it first prevents the backend conflict.

2. Extended the existing pip install block with 7 ML training packages: `transformers`, `accelerate`, `peft`, `trl`, `sentencepiece`, `hf_transfer`, `pyyaml`. Packages are separated from the existing data/utility packages by a comment for readability.

`eval-toolbox/Dockerfile` and `data-toolbox/Dockerfile` are unchanged — they inherit via `FROM base-toolbox:latest`.

## Commits

| Task | Description | Commit | Files |
|------|-------------|--------|-------|
| 1 | Add keras conflict fix and ML training deps | 626269e | base-toolbox/Dockerfile |

## Verification

- keras-nlp uninstall line present before pip install block: PASS
- All 7 packages (transformers, accelerate, peft, trl, sentencepiece, hf_transfer, pyyaml) in pip install: PASS
- eval-toolbox/Dockerfile unchanged: PASS
- data-toolbox/Dockerfile unchanged: PASS
- Dockerfile layer structure valid (each RUN ends properly, backslash continuations correct): PASS

## Deviations from Plan

None — plan executed exactly as written.

## Known Stubs

None.

## Self-Check: PASSED

- base-toolbox/Dockerfile modified and committed at 626269e
- All 8 verification grep checks pass
- Downstream Dockerfiles unmodified
