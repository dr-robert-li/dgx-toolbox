# Phase 11: Pipeline Wiring - Context

**Gathered:** 2026-03-24
**Status:** Ready for planning

<domain>
## Phase Boundary

Config + glue scripts connecting autoresearch to local data sources and HF cache models, post-training safety eval hook with temporary vLLM instance, and automatic model registration in LiteLLM for inference behind the harness. All bash scripts — no new Python systems.

</domain>

<decisions>
## Implementation Decisions

### Data discovery UX
- **Add option 6** to the existing launcher select menu: "Local datasets (auto-discovered)". Lists `~/data/` subdirs with file counts. User picks one. Existing 5 options unchanged
- **HF cache model discovery**: After data source selection, new step scans `~/.cache/huggingface/hub/` for model dirs, lists them with sizes, user picks one as the base model for training

### Training data screening
- **Batch pre-screen script**: Standalone `scripts/screen-data.sh` that reads each record from the dataset, sends through harness input guardrails API, outputs a cleaned dataset + report. Runs BEFORE autoresearch's `prepare.py`
- **Flagged records**: Removed from dataset. Separate log file lists what was removed and why (PII, toxicity, etc.). User can review log and manually restore false positives

### Post-training eval hook
- **Post-run script**: Separate `scripts/eval-checkpoint.sh` that the user runs after autoresearch finishes. NOT embedded in autoresearch's experiment loop — no patching of upstream source
- **Temporary vLLM instance**: Script starts a temp vLLM container with the checkpoint on a different port, runs harness replay eval against it, then stops the container. Self-contained — doesn't affect running services
- **Results storage**: `safety-eval.json` written alongside checkpoint files in the checkpoint dir. Simple, self-contained, git-trackable. Contains pass/fail, F1, scores, timestamp
- **Non-destructive**: Failing checkpoints are flagged with a warning but not deleted

### Model registration flow
- **Automatic after pass**: Eval script automatically registers passing checkpoints by appending a model entry to `~/.litellm/config.yaml`. User restarts LiteLLM to pick it up
- **Model naming**: Pattern `autoresearch/{experiment-dir-name}` (e.g., `autoresearch/exp-20260324`). Clear provenance from the experiment directory name
- **Deregistration**: `autoresearch-deregister <model-name>` command removes the entry from LiteLLM config

### Claude's Discretion
- Temp vLLM port number (e.g., :8021 to avoid conflict with :8020)
- LiteLLM config YAML append/remove implementation details
- Screen-data.sh input format handling (txt vs parquet vs jsonl)
- How to detect the "latest checkpoint" directory in autoresearch output
- Whether to auto-restart LiteLLM after registration or just print a reminder

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Existing autoresearch scripts
- `karpathy-autoresearch/launch-autoresearch.sh` — Interactive launcher with 5-option data source menu; add option 6 here
- `karpathy-autoresearch/launch-autoresearch-sync.sh` — Headless NVIDIA Sync variant; may need parallel updates
- `karpathy-autoresearch/spark-config.sh` — DGX Spark GPU tuning overrides

### Existing harness infrastructure
- `harness/eval/__main__.py` — Replay eval CLI (`python -m harness.eval replay --dataset ... --api-key ... --model ...`)
- `harness/eval/datasets/safety-core.jsonl` — Starter safety dataset for replay eval
- `harness/proxy/litellm.py` — Harness gateway POST /v1/chat/completions
- `harness/config/tenants.yaml` — API keys for eval requests

### Infrastructure config
- `~/.litellm/config.yaml` — LiteLLM model list; registration appends here
- `docker-compose.inference.yml` — vLLM container config; temp instance uses same image
- `inference/start-litellm.sh` — LiteLLM startup for reference

### Project context
- `.planning/PROJECT.md` — v1.2 Autoresearch Integration goals
- `.planning/REQUIREMENTS.md` — DATA-01 through MREG-03

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `launch-autoresearch.sh`: Existing 5-option select menu — add option 6 for auto-discovered datasets
- `harness/eval/__main__.py`: Replay eval CLI — eval-checkpoint.sh calls this
- `docker-compose.inference.yml`: vLLM container config — temp instance reuses the same image with different port/model
- `inference/setup-litellm-config.sh`: Pattern for writing LiteLLM config YAML

### Established Patterns
- Bash scripts with `set -euo pipefail` and `#!/usr/bin/env bash`
- `lib.sh` sourced for shared functions
- YAML for LiteLLM config
- Docker containers for model serving
- `select` menu for interactive options

### Integration Points
- `launch-autoresearch.sh` line 57 — `select` menu: add option 6
- `~/.litellm/config.yaml` — append/remove model entries
- `~/autoresearch/` — checkpoint output directory
- Harness on :5000 — eval requests go here
- vLLM on :8020 — temp instance on different port (:8021)

</code_context>

<specifics>
## Specific Ideas

- The screen-data script needs the harness running on :5000 to send guardrail check requests
- Eval-checkpoint.sh workflow: find latest checkpoint → start temp vLLM on :8021 → wait for model load → run harness replay → write safety-eval.json → stop temp vLLM → register if pass
- Model registration is a YAML append — `yq` or `sed` or Python one-liner to add an entry to `~/.litellm/config.yaml`
- Deregistration is the reverse: remove the matching entry from the YAML

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 11-pipeline-wiring*
*Context gathered: 2026-03-24*
