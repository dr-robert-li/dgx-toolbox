# Phase 11: Pipeline Wiring - Research

**Researched:** 2026-03-24
**Domain:** Bash glue scripts — dataset discovery, data screening, post-training eval, model registration
**Confidence:** HIGH (all sources are the actual codebase on this machine)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Add **option 6** to existing launcher select menu: "Local datasets (auto-discovered)". Lists `~/data/` subdirs with file counts. Existing 5 options unchanged.
- **HF cache model discovery**: After data source selection, new step scans `~/.cache/huggingface/hub/` for model dirs, lists them with sizes, user picks one as the base model for training.
- **Batch pre-screen script**: Standalone `scripts/screen-data.sh` that reads each record from the dataset, sends through harness input guardrails API, outputs a cleaned dataset + report. Runs BEFORE autoresearch's `prepare.py`. Flagged records removed, separate log file lists removed records and why.
- **Post-run script**: Separate `scripts/eval-checkpoint.sh` that the user runs after autoresearch finishes. NOT embedded in autoresearch's experiment loop — no patching of upstream source.
- **Temporary vLLM instance**: Script starts a temp vLLM container with the checkpoint on a different port, runs harness replay eval against it, then stops the container. Self-contained — doesn't affect running services.
- **Results storage**: `safety-eval.json` written alongside checkpoint files in the checkpoint dir. Contains pass/fail, F1, scores, timestamp.
- **Non-destructive**: Failing checkpoints are flagged with a warning but not deleted.
- **Automatic after pass**: Eval script automatically registers passing checkpoints by appending a model entry to `~/.litellm/config.yaml`.
- **Model naming**: Pattern `autoresearch/{experiment-dir-name}`.
- **Deregistration**: `autoresearch-deregister <model-name>` command removes entry from LiteLLM config.

### Claude's Discretion
- Temp vLLM port number (e.g., :8021 to avoid conflict with :8020)
- LiteLLM config YAML append/remove implementation details
- screen-data.sh input format handling (txt vs parquet vs jsonl)
- How to detect the "latest checkpoint" directory in autoresearch output
- Whether to auto-restart LiteLLM after registration or just print a reminder

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| DATA-01 | Autoresearch launcher auto-discovers datasets in `~/data/` subdirectories and presents them as data source options | `~/data/` exists with 5 subdirs (curated/, exports/, processed/, raw/, synthetic/). Option 6 slot available in existing `select` menu at launcher line 57. |
| DATA-02 | Autoresearch launcher can use a local HF cache model as the base model for training (auto-detected from `~/.cache/huggingface/hub/`) | 8 model dirs present in HF cache with real sizes (7.5G, 2.8G, 11M etc). Pattern: `models--{org}--{name}/`. `du -sh` gives sizes. |
| DATA-03 | Training data is optionally screened through harness input guardrails (PII, toxicity) before feeding to autoresearch | Harness POST /v1/chat/completions on :5000 works with ci-runner tenant (bypass=true, no guardrails) but can also use dev-team tenant. For screening, need to send direct guardrail check, not chat completions. See architecture notes below. |
| TRSF-01 | Post-training hook runs harness safety replay dataset against each trained checkpoint and logs pass/fail | `python -m harness.eval replay --dataset harness/eval/datasets/safety-core.jsonl --gateway http://localhost:5000 --api-key ... --model ...` produces F1/pass-fail output. Checkpoint requires vLLM serving. |
| TRSF-02 | Checkpoints that fail safety eval are flagged with a warning but not deleted | Script writes `safety-eval.json`, exits 0 (non-destructive). Warning printed to stderr. |
| TRSF-03 | Safety eval results stored alongside autoresearch experiment log | `safety-eval.json` written to checkpoint dir. See Critical Finding about checkpoint location. |
| MREG-01 | Passing checkpoints auto-registered in LiteLLM config | Append YAML block to `~/.litellm/config.yaml`. Python + pyyaml (confirmed available). Pattern from `setup-litellm-config.sh`. |
| MREG-02 | Registered models servable via vLLM and accessible through harness gateway on :5000 | Harness on :5000 → LiteLLM on :4000 → vLLM on :8020. New model on :8020 registered in LiteLLM as `openai/{model}` pointing at `http://host.docker.internal:8020/v1`. |
| MREG-03 | Deregistration command removes trained model from LiteLLM config | Python one-liner removes matching entry. Script: `scripts/autoresearch-deregister.sh`. |
</phase_requirements>

---

## Summary

Phase 11 is entirely bash scripts (4-5 files) that wire existing infrastructure together. No new Python systems. All integration points exist and are working on this machine.

**Critical Finding:** karpathy/autoresearch does NOT save model checkpoints by default. The training loop runs in memory and exits without writing weights to disk. This is by design — autoresearch is a research tool for improving training *code* (via git commits), not a fine-tuning pipeline for producing deployable models. The `eval-checkpoint.sh` and model registration scripts must account for this: they should operate on checkpoints that the *user has manually saved* (e.g., by patching train.py to call `torch.save()`), or the scripts must prompt the user for a checkpoint path rather than auto-discovering one.

**Primary recommendation:** `eval-checkpoint.sh` accepts a checkpoint path as a required argument. User runs it with the path to their checkpoint directory. Script validates the path contains HF-format weights (`config.json` + `*.safetensors` or `pytorch_model.bin`), starts temp vLLM, runs replay eval, writes `safety-eval.json` alongside, registers on pass.

**Data screening architecture:** The harness exposes guardrail checks through `/v1/chat/completions` but `screen-data.sh` needs raw guardrail verdicts, not chat responses. The cleanest approach is to call the harness gateway directly (which returns blocked/allowed in the response body) using the `ci-runner` API key with `bypass=false` to exercise guardrails. A blocked request returns HTTP 400 with a structured refusal — screen-data.sh interprets 400 as "flagged record".

---

## Standard Stack

### Core
| Library/Tool | Version | Purpose | Why Standard |
|---|---|---|---|
| bash | system | All scripts | Project convention — bash only, no new Python |
| docker run | 29.1.3 | Temp vLLM container | vLLM already runs as Docker container on this machine |
| python3 + pyyaml | system (confirmed) | YAML append/remove for LiteLLM config | pyyaml confirmed installed; ruamel.yaml also available but pyyaml sufficient for append |
| curl | system | HTTP requests to harness API for screen-data.sh | Simple, no deps |

### Supporting
| Library/Tool | Version | Purpose | When to Use |
|---|---|---|---|
| python3 + json | system | Parse JSON responses from harness | screen-data.sh response parsing |
| du -sh | system | Get HF model dir sizes for display | DATA-02 model listing |
| find | system | Discover ~/data/ subdirs, count files | DATA-01 dataset listing |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|---|---|---|
| pyyaml for YAML | yq | yq not installed on this machine; pyyaml confirmed available |
| python3 for YAML | sed/awk | YAML is structured; text-mangling risks corruption; python3 safer |
| docker run (inline) | docker-compose | No need for a new compose file; temp container is one-shot, not persistent |

**No new package installations required.** All tools are present.

---

## Architecture Patterns

### Recommended Project Structure
```
scripts/
├── screen-data.sh          # DATA-03: pre-screen dataset through harness guardrails
├── eval-checkpoint.sh      # TRSF-01/02/03: post-training safety eval + registration
└── autoresearch-deregister.sh  # MREG-03: remove model from LiteLLM config

karpathy-autoresearch/
├── launch-autoresearch.sh  # MODIFY: add option 6 + HF model selection step
└── launch-autoresearch-sync.sh  # MODIFY: add local-datasets source + HF model env var
```

### Pattern 1: Option 6 — Local Dataset Discovery (DATA-01)
**What:** Add case to existing `select` menu in `launch-autoresearch.sh`
**When to use:** User wants to train on a dataset from `~/data/`
**Integration point:** After the existing 5 options, before the `*)` fallback. Update error message from "1 and 5" to "1 and 6".

Key implementation — list `~/data/` subdirs with file counts:
```bash
# Build dynamic list of ~/data/ subdirs with file counts
_discover_local_datasets() {
  local datasets=()
  while IFS= read -r -d '' subdir; do
    local name
    name=$(basename "$subdir")
    local count
    count=$(find "$subdir" -maxdepth 1 \( -name "*.txt" -o -name "*.parquet" -o -name "*.jsonl" \) | wc -l)
    datasets+=("${name} (${count} files)")
  done < <(find "${HOME}/data" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
  printf '%s\n' "${datasets[@]}"
}
```

Then user picks a subdir name; expand to full path `${HOME}/data/${chosen_name}` and copy `.txt`/`.parquet` files to `${AUTORESEARCH_DIR}/data/` using the same pattern as the existing "Local directory" case.

### Pattern 2: HF Cache Model Discovery (DATA-02)
**What:** After data source selection, new interactive step before DGX tuning application
**When to use:** After any data source is processed; user may want to use a local HF model as base
**Implementation:** Scan `~/.cache/huggingface/hub/models--*` dirs, show name + size, present `select` menu.

```bash
# HF model selection step (add between data source and DGX tuning sections)
_select_hf_model() {
  local hf_hub="${HOME}/.cache/huggingface/hub"
  local model_dirs=()
  local model_names=()

  while IFS= read -r -d '' dir; do
    local basename
    basename=$(basename "$dir")
    # Convert models--org--name -> org/name
    local model_name="${basename#models--}"
    model_name="${model_name/--//}"
    local size
    size=$(du -sh "$dir" 2>/dev/null | cut -f1)
    model_dirs+=("$dir")
    model_names+=("${model_name} [${size}]")
  done < <(find "$hf_hub" -mindepth 1 -maxdepth 1 -type d -name 'models--*' -print0 | sort -z)

  if [ ${#model_names[@]} -eq 0 ]; then
    echo "No models found in HF cache. Continuing with autoresearch default."
    return
  fi

  echo ""
  echo "Select base model for training (HF cache):"
  select choice in "${model_names[@]}" "Skip (use autoresearch default)"; do
    if [[ "$REPLY" -le ${#model_names[@]} && "$REPLY" -gt 0 ]]; then
      HF_BASE_MODEL="${model_dirs[$((REPLY-1))]}/snapshots"
      # Get the latest snapshot
      HF_BASE_MODEL=$(ls -td "${model_dirs[$((REPLY-1))]}/snapshots/"* 2>/dev/null | head -1)
      echo "Base model: ${model_names[$((REPLY-1))]}"
      export AUTORESEARCH_BASE_MODEL="$HF_BASE_MODEL"
      break
    elif [[ "$REPLY" -eq $((${#model_names[@]}+1)) ]]; then
      echo "Skipping HF model selection."
      break
    fi
  done
}
```

HF snapshot path structure (verified on this machine): `models--{org}--{name}/snapshots/{hash}/`

### Pattern 3: screen-data.sh — Dataset Pre-Screening (DATA-03)
**What:** Standalone script that sends each record through harness guardrail input check, removes flagged records
**Design:** Call harness POST /v1/chat/completions with `dev-team` API key (bypass=false, guardrails active). HTTP 400 response = blocked/flagged. HTTP 200 = clean. Write clean records to output file.
**Input formats to handle:** `.jsonl` (one JSON per line), `.txt` (one record per line), `.parquet` (requires python3 + pandas)

```bash
#!/usr/bin/env bash
set -euo pipefail
# Usage: screen-data.sh <input_file> <output_dir>
# Sends each record through harness input guardrails (POST /v1/chat/completions on :5000)
# Clean records -> output_dir/<basename>-screened.<ext>
# Removed records -> output_dir/<basename>-removed.log

HARNESS_URL="${HARNESS_URL:-http://localhost:5000}"
HARNESS_API_KEY="${HARNESS_API_KEY:-}"  # Required: set via env or arg

# For .jsonl: each line is {"prompt": "..."} or {"messages": [...]}
# For .txt: each non-empty line becomes a single-message prompt
# Strategy: normalize all records to {"messages": [{"role":"user","content":"..."}]}
# and POST to /v1/chat/completions. HTTP 400 = blocked. HTTP 200 = clean.
```

**Important:** The harness `ci-runner` tenant has `bypass=true` — it skips guardrails. Use `dev-team` tenant API key for actual screening (bypass=false). The dev-team API key hash is in `harness/config/tenants.yaml`; the actual key must come from the user's environment or the harness `.env` file.

**Harness must be running** at :5000 for screen-data.sh to work. Script must check this upfront and exit with clear error if harness is not reachable.

### Pattern 4: eval-checkpoint.sh — Post-Training Safety Eval (TRSF-01/02/03)
**What:** User runs this after training. Takes checkpoint path as argument.
**Workflow:**
1. Validate checkpoint dir contains HF-format weights
2. Start temp vLLM container on :8021 (`vllm-tmp`) with `--trust-remote-code`
3. Poll until model loads (GET /v1/models endpoint returns 200)
4. Run `python -m harness.eval replay --dataset harness/eval/datasets/safety-core.jsonl --gateway http://localhost:5000 --api-key ${HARNESS_API_KEY} --model autoresearch/${EXPERIMENT_NAME}`
5. Parse output for F1 score, pass/fail determination
6. Write `safety-eval.json` to checkpoint dir
7. Stop and remove temp vLLM container
8. If pass: append model entry to `~/.litellm/config.yaml`, print restart reminder
9. If fail: print warning, exit 0 (non-destructive)

**Critical detail for replay eval:** The replay eval sends requests through the harness gateway (`:5000`), which proxies to LiteLLM (`:4000`), which needs to know about the model. The temp vLLM is on `:8021`, but LiteLLM doesn't know about it yet. Solution: **register the model in LiteLLM temporarily** before running eval, then do the permanent registration only on pass. Or: point the gateway directly at the temp vLLM at :8021 using `--gateway http://localhost:8021` flag — this bypasses LiteLLM entirely and hits vLLM's OpenAI-compatible API directly. This is simpler and avoids modifying LiteLLM mid-eval.

**Recommended approach:** `--gateway http://localhost:8021` for the eval, then register in LiteLLM after pass. The replay eval uses `/v1/chat/completions` which vLLM serves directly.

**Pass threshold:** F1 >= 0.80 is a reasonable default (matching Phase 8 eval gate). Make configurable via `EVAL_F1_THRESHOLD` env var.

```bash
# Temp vLLM container launch pattern (reuses same image as production)
docker run -d \
  --name vllm-tmp \
  --gpus all \
  --ipc=host \
  -p 0.0.0.0:8021:8000 \
  -v "${HOME}/.cache/huggingface:/root/.cache/huggingface" \
  -v "${CHECKPOINT_DIR}:/checkpoint" \
  vllm/vllm-openai:latest \
  --model /checkpoint \
  --host 0.0.0.0 \
  --port 8000 \
  --trust-remote-code \
  --gpu-memory-utilization 0.5
```

**Wait loop pattern (poll until model ready):**
```bash
_wait_vllm_ready() {
  local port="$1" max_wait="${2:-120}" interval=5 elapsed=0
  echo "Waiting for vLLM on :${port}..."
  while [ "$elapsed" -lt "$max_wait" ]; do
    if curl -sf "http://localhost:${port}/v1/models" >/dev/null 2>&1; then
      echo "vLLM ready after ${elapsed}s"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  echo "ERROR: vLLM did not become ready within ${max_wait}s" >&2
  return 1
}
```

**Port conflict note:** :8021 is currently free on this machine (verified: no container or process uses it). :8020 is taken by production vLLM.

**GPU conflict note:** Both production vLLM (`:8020`) and temp vLLM (`:8021`) request `--gpus all`. On DGX Spark with unified memory, running two vLLM instances simultaneously is likely to cause OOM or CUDA errors. The eval script should **warn the user** that the production vLLM will compete for GPU memory. Recommended: stop production vLLM before eval, restart after. Or use `--gpu-memory-utilization 0.3` for the temp instance and hope for the best. Document this limitation clearly.

### Pattern 5: LiteLLM YAML Registration (MREG-01/03)
**What:** Append and remove model entries in `~/.litellm/config.yaml`
**Tool:** Python + pyyaml (confirmed available; yq not installed)

Registration pattern (append):
```python
#!/usr/bin/env python3
# Usage: python3 scripts/_litellm_register.py <model_name> <api_base>
import sys, yaml

config_path = os.path.expanduser("~/.litellm/config.yaml")
model_name = sys.argv[1]   # e.g. autoresearch/exp-20260324
api_base = sys.argv[2]     # e.g. http://localhost:8020/v1

with open(config_path) as f:
    config = yaml.safe_load(f)

new_entry = {
    "model_name": model_name,
    "litellm_params": {
        "model": f"openai/{model_name}",
        "api_base": api_base,
        "api_key": "none"
    }
}

# Check for duplicate
existing = [m["model_name"] for m in config.get("model_list", [])]
if model_name not in existing:
    config.setdefault("model_list", []).append(new_entry)
    with open(config_path, "w") as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
    print(f"Registered: {model_name}")
else:
    print(f"Already registered: {model_name}")
```

Deregistration pattern (remove):
```python
config["model_list"] = [
    m for m in config.get("model_list", [])
    if m["model_name"] != model_name
]
```

**yaml.dump caveat:** pyyaml's `yaml.dump()` does NOT preserve comments. The `~/.litellm/config.yaml` has comments (e.g., `# --- vLLM model (localhost:8020) ---`). After a dump-write cycle, all comments are lost. **Use append-without-reload instead:** append the raw YAML block as a string to the file rather than parse-modify-dump. This preserves existing comments.

String-append pattern (comment-safe):
```bash
# In eval-checkpoint.sh, after pass:
cat >> "${HOME}/.litellm/config.yaml" << YAML

  # --- autoresearch checkpoint (registered $(date -u +%Y-%m-%dT%H:%M:%SZ)) ---
  - model_name: ${MODEL_NAME}
    litellm_params:
      model: openai/${MODEL_NAME}
      api_base: http://host.docker.internal:8020/v1
      api_key: "none"
YAML
```

For deregistration, Python is still needed because we need to remove a multi-line block. Use pyyaml parse-modify-dump — comments in the deregister case are already partly gone (only the autoresearch entries are touched; but user should be warned about comment loss). Alternative: use grep to find the block and `sed` to delete N lines starting at the match. The safer approach is to use Python but accept comment loss on deregister, or use a sentinel comment pattern.

### Pattern 6: safety-eval.json Schema (TRSF-03)
```json
{
  "checkpoint": "/path/to/checkpoint",
  "experiment_name": "exp-20260324",
  "model_name": "autoresearch/exp-20260324",
  "dataset": "harness/eval/datasets/safety-core.jsonl",
  "timestamp": "2026-03-24T12:00:00Z",
  "passed": true,
  "f1": 0.923,
  "precision": 0.910,
  "recall": 0.937,
  "correct_refusal_rate": 0.937,
  "false_refusal_rate": 0.021,
  "total_cases": 50,
  "f1_threshold": 0.80,
  "registered": true,
  "litellm_model_name": "autoresearch/exp-20260324"
}
```

### Anti-Patterns to Avoid
- **Patching autoresearch source**: CONTEXT.md is explicit — no patching of upstream autoresearch code. All eval/registration is post-run via separate scripts.
- **Assuming checkpoints exist**: autoresearch does not save checkpoints by default. eval-checkpoint.sh MUST validate the checkpoint path before proceeding.
- **Running two vLLM instances on full GPU**: GPU conflict is real. Script must warn and provide an option to stop/restart production vLLM.
- **yaml.dump() destroying comments**: Use string-append for registration; accept comment loss for deregistration with a clear warning.
- **ci-runner API key for screening**: ci-runner has `bypass=true` — guardrails don't run. Use dev-team key for actual screening.
- **Auto-restart LiteLLM**: docker restart loses port bindings in some configs. Print a reminder instead. The CONTEXT.md says "Claude's discretion" here — the safer choice is reminder-only.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---|---|---|---|
| Safety eval scoring | Custom eval loop | `python -m harness.eval replay` | Existing Phase 8 eval harness with F1, CRR, FRR already works |
| vLLM serving | Custom inference server | `vllm/vllm-openai:latest` Docker image | Already on this machine, already used in production |
| HF model loading | Manual weight loading | vLLM's `--model /path` with `--trust-remote-code` | vLLM handles all HF format variants |
| YAML config management | Full YAML parser round-trip | String-append for add, pyyaml for remove | Avoids comment destruction on the hot path |

---

## Common Pitfalls

### Pitfall 1: autoresearch Checkpoint Discovery Assumption
**What goes wrong:** Script assumes `~/autoresearch/out/` or similar contains HF-format checkpoint dirs and auto-discovers "the latest one"
**Why it happens:** Common pattern in fine-tuning pipelines, but autoresearch is a research tool, not a fine-tuner
**How to avoid:** `eval-checkpoint.sh` requires a positional argument `<checkpoint_dir>`. Validate it contains `config.json` (HF model format marker) before proceeding.
**Warning signs:** Script trying to `find ~/autoresearch -name "config.json"` without any confirmation step

### Pitfall 2: GPU Memory Conflict
**What goes wrong:** Starting temp vLLM on :8021 while production vLLM runs on :8020 causes OOM or CUDA device initialization failure
**Why it happens:** Both containers use `--gpus all`; DGX Spark has unified memory shared across processes
**How to avoid:** Detect if production vLLM is running before starting temp instance. Print explicit warning. Offer `--stop-vllm` flag to temporarily stop production vLLM.
**Warning signs:** `docker run` exits immediately with CUDA error; `nvidia-smi` shows high memory utilization

### Pitfall 3: Harness Not Running for screen-data.sh
**What goes wrong:** screen-data.sh calls :5000 but harness is not running → 100% of records "fail" silently
**Why it happens:** Script doesn't pre-check harness availability
**How to avoid:** Probe `http://localhost:5000/health` (or `GET /`) at startup. Exit with clear error if not reachable. Harness must be running before invoking screen-data.sh.
**Warning signs:** All records appear flagged; curl returns connection refused

### Pitfall 4: Wrong API Key for Guardrail Screening
**What goes wrong:** screen-data.sh uses `ci-runner` key (bypass=true), so no guardrails actually run and all records pass
**Why it happens:** ci-runner key is the "easy" key for CI; its bypass=true flag disables guardrails
**How to avoid:** screen-data.sh requires `HARNESS_API_KEY` env var; documentation must state this must be the dev-team key (or any non-bypass tenant)

### Pitfall 5: LiteLLM Config Comment Destruction
**What goes wrong:** pyyaml parse-modify-dump strips all comments from `~/.litellm/config.yaml`; user's manual annotations are lost
**Why it happens:** pyyaml doesn't preserve YAML comments
**How to avoid:** Use string-append for registration (avoids parse round-trip). For deregistration, warn user that comments may be lost and backup the file first.

### Pitfall 6: Duplicate Model Registration
**What goes wrong:** Running eval-checkpoint.sh twice on the same checkpoint registers the model twice in LiteLLM
**Why it happens:** String-append doesn't check for duplicates
**How to avoid:** Before appending, grep `~/.litellm/config.yaml` for the model name. If found, skip registration and print "already registered" message.

### Pitfall 7: Temp vLLM Container Leak on Failure
**What goes wrong:** eval-checkpoint.sh fails mid-run (e.g., replay eval crashes), leaving `vllm-tmp` container running
**Why it happens:** `set -euo pipefail` exits immediately on error; cleanup code not reached
**How to avoid:** Use a `trap` to always stop and remove the temp container:
```bash
trap 'docker stop vllm-tmp 2>/dev/null; docker rm vllm-tmp 2>/dev/null' EXIT
```

### Pitfall 8: sync launcher missing local-datasets support
**What goes wrong:** `launch-autoresearch-sync.sh` only has 5 data sources; headless/NVIDIA Sync users can't use local dataset discovery
**Why it happens:** Option 6 only added to interactive launcher
**How to avoid:** Add `local-datasets` as a new `AUTORESEARCH_DATA_SOURCE` value to `launch-autoresearch-sync.sh`. Use `AUTORESEARCH_DATA_PATH` to specify which `~/data/` subdir by name.

---

## Code Examples

Verified patterns from existing codebase:

### HF Hub Dir to Model Name Conversion
```bash
# ~/.cache/huggingface/hub/models--nvidia--NVIDIA-Nemotron-3-Nano-4B-BF16
# -> nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16
basename_to_model() {
  local bn="$1"
  local stripped="${bn#models--}"
  echo "${stripped/--//}"
}
```
Verified: `models--nvidia--NVIDIA-Nemotron-3-Nano-4B-BF16` → `nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16`

### HF Snapshot Path (Latest)
```bash
SNAPSHOT_DIR=$(ls -td "${HF_CACHE}/models--${org}--${name}/snapshots/"* 2>/dev/null | head -1)
```
Verified structure: `snapshots/{single_hash_dir}/` on this machine (only one snapshot per model)

### replay eval invocation
```bash
cd /path/to/dgx-toolbox
python -m harness.eval replay \
  --dataset harness/eval/datasets/safety-core.jsonl \
  --gateway http://localhost:8021 \
  --api-key "${HARNESS_API_KEY}" \
  --model "${MODEL_NAME}"
```
Note: `--gateway http://localhost:8021` routes directly to temp vLLM, bypassing LiteLLM and harness guardrails for the eval. The eval runner handles auth via the `--api-key` arg.

Wait — the replay eval hits the gateway which applies guardrails. For checkpoint eval we want to test the raw model's safety, not the harness+model combination. For TRSF-01 the intent is "run harness safety replay dataset against each trained checkpoint" — this implies the harness IS part of the eval (that's the safety stack). So `--gateway http://localhost:5000` with the model registered temporarily in LiteLLM, or `--gateway http://localhost:8021` without the harness. **The CONTEXT.md says "runs harness replay eval against it"** — the harness IS the gateway. So: temp register model in LiteLLM, run replay through :5000, then permanent-register on pass.

### Revised eval flow (gateway-aware):
```bash
# 1. Temp-register model in LiteLLM config
# 2. Reload LiteLLM (docker restart litellm)
# 3. Run replay: --gateway http://localhost:5000
# 4. Unregister temp entry regardless of outcome
# 5. If pass: permanent-register + remind user to restart LiteLLM
```
Or simpler: point replay directly at vLLM `:8021` bypassing the harness, measure raw model F1 against the safety dataset. This is arguably more informative (isolates the model from the harness) and avoids the temp-register dance.

**Recommendation (Claude's discretion):** Use `--gateway http://localhost:8021` direct to vLLM for eval. The safety eval measures whether the *model itself* has learned safety behaviors from training, not whether the harness guardrails catch things. This is consistent with "post-training safety eval hook" intent (evaluate training quality).

### docker run for temp vLLM (from existing start-vllm.sh pattern)
```bash
# Source: inference/start-vllm.sh (adapted)
docker run -d \
  --name vllm-tmp \
  --gpus all \
  --ipc=host \
  -p 0.0.0.0:8021:8000 \
  -v "${HOME}/.cache/huggingface:/root/.cache/huggingface" \
  -v "${CHECKPOINT_ABS}:/checkpoint:ro" \
  vllm/vllm-openai:latest \
  --model /checkpoint \
  --host 0.0.0.0 --port 8000 \
  --trust-remote-code \
  --gpu-memory-utilization 0.5
```

### Checking for duplicate model in LiteLLM config
```bash
if grep -q "model_name: ${MODEL_NAME}" "${HOME}/.litellm/config.yaml" 2>/dev/null; then
  echo "Model already registered: ${MODEL_NAME}"
  exit 0
fi
```

---

## State of the Art

| Old Approach | Current Approach | Impact |
|---|---|---|
| Manually editing LiteLLM config | Script-driven append/remove | Registration in one command |
| Running eval in the training loop | Standalone post-run script | No upstream patching required |
| Assuming fine-tuning output format | Explicit checkpoint path argument | Handles autoresearch's no-checkpoint-by-default reality |

---

## Open Questions

1. **Checkpoint format validation**
   - What we know: autoresearch does NOT save checkpoints by default; vLLM loads HF-format dirs with `config.json`
   - What's unclear: If a user has manually patched train.py to save checkpoints, what format will they be in? HF format requires `config.json` + `tokenizer.json` + weight files.
   - Recommendation: Validate checkpoint dir contains `config.json`. Print clear error if missing. Document that user must ensure HF-format output from their training run.

2. **GPU conflict during eval**
   - What we know: Production vLLM runs on :8020 with `--gpus all`; temp vLLM requests `--gpus all`
   - What's unclear: Will CUDA allow two vLLM processes on DGX Spark's unified memory simultaneously?
   - Recommendation: eval-checkpoint.sh warns user about GPU conflict. Provide `--stop-vllm` flag that stops production vLLM before eval and restarts after. Default behavior is warning-only.

3. **screen-data.sh parquet support**
   - What we know: autoresearch copies `.parquet` files; pandas/pyarrow may not be installed in the dgx-toolbox virtualenv
   - What's unclear: Is pandas available? The screen-data.sh needs to read parquet records.
   - Recommendation: Check for `python3 -c "import pandas"` at startup. If parquet and pandas unavailable, exit with clear error. For .txt and .jsonl, no special deps needed.

4. **eval-checkpoint.sh: direct vLLM vs. through harness**
   - What we know: replay eval CLI supports `--gateway` pointing anywhere with `/v1/chat/completions`
   - What's unclear: Should safety eval test model+harness stack or raw model?
   - Recommendation: Direct to vLLM on :8021 (tests raw model). Rationale: the eval measures whether training improved model safety, not whether harness catches things.

---

## Validation Architecture

nyquist_validation is enabled (config.json has `"nyquist_validation": true`).

### Test Framework
| Property | Value |
|----------|-------|
| Framework | bash inline assertion pattern (no bats — project convention from STATE.md) |
| Config file | none — inline test files |
| Quick run command | `bash scripts/test-pipeline-wiring.sh` |
| Full suite command | `bash scripts/test-pipeline-wiring.sh` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| DATA-01 | Option 6 appears in launcher menu for ~/data/ datasets | unit (script parse) | `bash scripts/test-pipeline-wiring.sh data-01` | Wave 0 |
| DATA-02 | HF cache scan lists models with sizes | unit (script output) | `bash scripts/test-pipeline-wiring.sh data-02` | Wave 0 |
| DATA-03 | screen-data.sh exits non-zero when harness unreachable | unit (mock curl) | `bash scripts/test-pipeline-wiring.sh data-03` | Wave 0 |
| TRSF-01 | eval-checkpoint.sh validates checkpoint dir has config.json | unit (missing dir) | `bash scripts/test-pipeline-wiring.sh trsf-01` | Wave 0 |
| TRSF-02 | eval-checkpoint.sh exits 0 on failed safety eval (non-destructive) | unit (mock replay) | `bash scripts/test-pipeline-wiring.sh trsf-02` | Wave 0 |
| TRSF-03 | safety-eval.json written to checkpoint dir | unit (mock replay output) | `bash scripts/test-pipeline-wiring.sh trsf-03` | Wave 0 |
| MREG-01 | Passing eval triggers append to ~/.litellm/config.yaml | unit (mock config) | `bash scripts/test-pipeline-wiring.sh mreg-01` | Wave 0 |
| MREG-02 | Registered model entry follows correct YAML schema | unit (grep output) | `bash scripts/test-pipeline-wiring.sh mreg-02` | Wave 0 |
| MREG-03 | autoresearch-deregister removes model_name block from config | unit (mock config) | `bash scripts/test-pipeline-wiring.sh mreg-03` | Wave 0 |

### Sampling Rate
- **Per task commit:** `bash scripts/test-pipeline-wiring.sh` (full suite, ~30s)
- **Per wave merge:** `bash scripts/test-pipeline-wiring.sh`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `scripts/test-pipeline-wiring.sh` — all 9 requirement tests
- [ ] `scripts/screen-data.sh` — DATA-03
- [ ] `scripts/eval-checkpoint.sh` — TRSF-01/02/03, MREG-01/02
- [ ] `scripts/autoresearch-deregister.sh` — MREG-03

*(All scripts are new; none exist yet. Wave 0 creates the test harness alongside the scripts.)*

---

## Sources

### Primary (HIGH confidence)
- `/home/robert_li/dgx-toolbox/karpathy-autoresearch/launch-autoresearch.sh` — select menu structure, option slots, data source patterns
- `/home/robert_li/dgx-toolbox/harness/eval/__main__.py` — replay CLI flags, output format
- `/home/robert_li/dgx-toolbox/docker-compose.inference.yml` — vLLM container image, port, volume mounts
- `/home/robert_li/.litellm/config.yaml` — exact YAML structure for model_list entries
- `/home/robert_li/dgx-toolbox/inference/setup-litellm-config.sh` — append pattern for LiteLLM YAML
- `/home/robert_li/dgx-toolbox/inference/start-vllm.sh` — docker run pattern for vLLM
- `/home/robert_li/dgx-toolbox/harness/config/tenants.yaml` — ci-runner bypass=true, dev-team bypass=false
- `~/.cache/huggingface/hub/` directory scan — actual model dirs, sizes, snapshot structure
- `~/data/` directory scan — 5 subdirs confirmed, all empty

### Secondary (MEDIUM confidence)
- `https://raw.githubusercontent.com/karpathy/autoresearch/master/train.py` — no checkpoint saving (verified via WebFetch)
- `https://raw.githubusercontent.com/karpathy/autoresearch/master/program.md` — experiment output format, results.tsv, no model weight persistence mentioned
- `https://raw.githubusercontent.com/karpathy/autoresearch/master/README.md` — autoresearch purpose confirmed as research tool not fine-tuning pipeline

### Tertiary (LOW confidence)
- GPU memory conflict between two simultaneous vLLM containers on DGX Spark — inferred from hardware specs; not empirically verified

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all tools verified present on this machine
- Architecture: HIGH — all integration points read from actual source files
- Pitfalls: MEDIUM-HIGH — most from direct code inspection; GPU conflict is inference
- autoresearch checkpoint behavior: HIGH — verified by reading actual train.py source

**Research date:** 2026-03-24
**Valid until:** 2026-04-24 (stable bash scripts; autoresearch upstream could change but we don't patch it)
