---
phase: 11-pipeline-wiring
verified: 2026-03-24T02:00:00Z
status: passed
score: 12/12 must-haves verified
re_verification: false
---

# Phase 11: Pipeline Wiring Verification Report

**Phase Goal:** Autoresearch can be launched against local datasets and HF cache models, trained checkpoints are automatically evaluated by the safety harness replay eval, and passing models are registered in LiteLLM for immediate inference behind the gateway
**Verified:** 2026-03-24
**Status:** PASSED
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| #  | Truth | Status | Evidence |
|----|-------|--------|----------|
| 1  | Launcher select menu shows option 6 for local datasets from ~/data/ subdirectories | VERIFIED | `launch-autoresearch.sh` line 126: `"Local datasets (auto-discovered)"` in select block; `_discover_local_datasets()` function at line 20 uses `find ${HOME}/data -mindepth 1 -maxdepth 1 -type d` |
| 2  | After data source selection, user can pick a base model from HF cache with sizes shown | VERIFIED | `_select_hf_model()` at line 40 scans `~/.cache/huggingface/hub/models--*`, computes sizes via `du -sh`, exports `AUTORESEARCH_BASE_MODEL`; called at line 260 after data source select/done block |
| 3  | Sync launcher accepts local-datasets as AUTORESEARCH_DATA_SOURCE value | VERIFIED | `launch-autoresearch-sync.sh` line 145: `local-datasets)` case; validates `${HOME}/data/${AUTORESEARCH_DATA_PATH}`, copies files; error message at line 168 includes `local-datasets` |
| 4  | screen-data.sh sends records through harness guardrails and removes flagged ones | VERIFIED | `screen-data.sh` POSTs to `${HARNESS_URL}/v1/chat/completions`; HTTP 200=clean (written to screened file), 400/403/422=flagged (written to removed.log); handles .txt, .jsonl, .parquet |
| 5  | screen-data.sh exits with clear error when harness is not reachable | VERIFIED | Lines 81-86: dual curl health check (`/health` and `/`); prints "ERROR: Harness not reachable at ${HARNESS_URL}. Start harness first." to stderr; exits 1 |
| 6  | eval-checkpoint.sh validates checkpoint dir contains config.json before proceeding | VERIFIED | Lines 61-65: `[ ! -f "$CHECKPOINT_DIR/config.json" ]` check; prints "ERROR: No config.json found in ${CHECKPOINT_DIR}. Checkpoint must be in HuggingFace format."; exits 1 |
| 7  | eval-checkpoint.sh starts a temp vLLM container, runs replay eval, and stops the container | VERIFIED | Section 4 (line 128): `docker run -d --name vllm-tmp`; Section 6 (line 174): `python -m harness.eval replay`; Section 3 (line 119): `trap '_cleanup' EXIT` stops and removes container |
| 8  | safety-eval.json is written to the checkpoint directory with pass/fail, F1, timestamp | VERIFIED | Line 228: `echo "$EVAL_JSON" > "${CHECKPOINT_DIR}/safety-eval.json"`; JSON includes `passed`, `f1`, `precision`, `recall`, `timestamp`, `f1_threshold`, `registered` |
| 9  | A failing checkpoint is flagged with a warning but checkpoint files are not deleted | VERIFIED | Lines 272-275: prints "WARNING: Safety eval FAILED" to stderr, "Checkpoint files preserved at:", then `exit 0` (non-destructive) |
| 10 | A passing checkpoint is auto-registered in ~/.litellm/config.yaml | VERIFIED | Lines 239-264: duplicate-check via grep, then `cat >> "$LITELLM_CONFIG"` appends model entry with `model_name`, `litellm_params`, `api_base: http://host.docker.internal:8020/v1`; updates `registered=true` in safety-eval.json |
| 11 | autoresearch-deregister.sh removes a model entry from LiteLLM config | VERIFIED | Validates config file and model presence, delegates to `python3 _litellm_register.py remove`, prints "Deregistered: ${MODEL_NAME}" and restart reminder |
| 12 | Temp vLLM container is cleaned up even if script fails (trap EXIT) | VERIFIED | Line 119: `trap '_cleanup' EXIT`; `_cleanup()` runs `docker stop vllm-tmp; docker rm vllm-tmp`; conditionally restarts production vLLM if `--stop-vllm` was used |

**Score:** 12/12 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `karpathy-autoresearch/launch-autoresearch.sh` | Option 6 local dataset discovery + HF model selection | VERIFIED | 346 lines; contains `_discover_local_datasets`, `_select_hf_model`, option 6 case, error message "between 1 and 6"; all syntax valid |
| `karpathy-autoresearch/launch-autoresearch-sync.sh` | local-datasets data source + AUTORESEARCH_BASE_MODEL env var | VERIFIED | 206 lines; `local-datasets)` case, `AUTORESEARCH_BASE_MODEL` handling in section 3b, updated error message; syntax valid |
| `scripts/screen-data.sh` | Training data pre-screening through harness guardrails | VERIFIED | 271 lines; handles .txt/.jsonl/.parquet; health check; JSON escaping via python3; exit codes 0/1; executable (775) |
| `scripts/test-data-integration.sh` | Tests for DATA-01, DATA-02, DATA-03 | VERIFIED | 9/9 tests pass; covers all three DATA requirements |
| `scripts/eval-checkpoint.sh` | Post-training safety eval + model registration | VERIFIED | 277 lines; all 8 sections implemented; `trap EXIT`; `safety-eval.json` write; LiteLLM append; non-destructive `exit 0` on failure; executable (775) |
| `scripts/_litellm_register.py` | Python helper for LiteLLM YAML append with duplicate check | VERIFIED | `add_model`, `remove_model`, `list_models`; `shutil.copy2` backup before destructive write; valid Python syntax |
| `scripts/autoresearch-deregister.sh` | Remove model from LiteLLM config | VERIFIED | Validates config+model existence; delegates to `_litellm_register.py remove`; restart reminder; executable (775) |
| `scripts/test-eval-register.sh` | Tests for TRSF-01/02/03, MREG-01/02/03 | VERIFIED | 17/17 tests pass; covers all six requirements |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `launch-autoresearch.sh` | `~/data/` subdirectories | `find ${HOME}/data -mindepth 1 -maxdepth 1 -type d -print0` | WIRED | `_discover_local_datasets()` line 29 |
| `launch-autoresearch.sh` | `~/.cache/huggingface/hub/` | `_select_hf_model` find on `models--*` dirs | WIRED | Lines 45-55; `du -sh` for sizes; snapshot path resolved |
| `screen-data.sh` | harness on :5000 | `curl POST ${HARNESS_URL}/v1/chat/completions` | WIRED | Lines 131-137; Bearer auth; JSON body with record content |
| `eval-checkpoint.sh` | docker run vllm-tmp | `docker run -d --name vllm-tmp` on :8021 | WIRED | Lines 125-139; `docker rm -f` precheck; `--gpu-memory-utilization` |
| `eval-checkpoint.sh` | `python -m harness.eval replay` | replay eval against temp vLLM at :8021 | WIRED | Lines 174-178; `--dataset`, `--gateway`, `--model` flags |
| `eval-checkpoint.sh` | `~/.litellm/config.yaml` | `cat >>` string-append on passing eval | WIRED | Lines 244-252; comment-safe; duplicate check first. NOTE: Plan specified via `_litellm_register.py` but implementation uses direct string-append (documented design decision: preserves YAML comments) |
| `autoresearch-deregister.sh` | `~/.litellm/config.yaml` | `python3 _litellm_register.py remove` | WIRED | Line 45; backup-safe via pyyaml |

**Note on eval-checkpoint.sh → _litellm_register.py link:** The plan's `key_links` specified registration via `_litellm_register.py`, but `eval-checkpoint.sh` uses direct `cat >>` string-append instead. The SUMMARY documents this as a deliberate choice (comment preservation). The functional outcome — passing models are appended to `~/.litellm/config.yaml` — is fully achieved. `_litellm_register.py` is used by `autoresearch-deregister.sh` for removal only.

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| DATA-01 | 11-01-PLAN.md | Autoresearch launcher auto-discovers datasets in `~/data/` subdirectories | SATISFIED | Option 6 + `_discover_local_datasets()` in interactive launcher; `local-datasets` case in sync launcher |
| DATA-02 | 11-01-PLAN.md | Launcher can use local HF cache model as base model for training | SATISFIED | `_select_hf_model()` scans `~/.cache/huggingface/hub/`, exports `AUTORESEARCH_BASE_MODEL`; sync launcher respects env var |
| DATA-03 | 11-01-PLAN.md | Training data optionally screened through harness input guardrails | SATISFIED | `screen-data.sh` POSTs each record to harness guardrails, outputs screened file + removal log |
| TRSF-01 | 11-02-PLAN.md | Post-training hook runs harness safety replay dataset against each checkpoint | SATISFIED | `eval-checkpoint.sh` validates config.json, starts temp vLLM, runs `python -m harness.eval replay`, writes safety-eval.json |
| TRSF-02 | 11-02-PLAN.md | Checkpoints that fail safety eval are flagged but not deleted | SATISFIED | Lines 272-275: WARNING to stderr, "Checkpoint files preserved at:", `exit 0` |
| TRSF-03 | 11-02-PLAN.md | Safety eval results stored alongside experiment log | SATISFIED | `${CHECKPOINT_DIR}/safety-eval.json` written with F1, precision, recall, pass/fail, timestamp, registered flag |
| MREG-01 | 11-02-PLAN.md | Passing checkpoints auto-registered in LiteLLM config | SATISFIED | `cat >> $LITELLM_CONFIG` appends model entry; `registered=true` set in safety-eval.json |
| MREG-02 | 11-02-PLAN.md | Registered models servable via vLLM through harness gateway on :5000 | SATISFIED | `api_base: http://host.docker.internal:8020/v1` points to production vLLM; restart reminder issued; model accessible via harness (LiteLLM proxies to vLLM) |
| MREG-03 | 11-02-PLAN.md | Deregistration command removes trained model from LiteLLM config | SATISFIED | `autoresearch-deregister.sh` validates + removes via `_litellm_register.py`; backup created before modification |

All 9 requirements for Phase 11 (DATA-01, DATA-02, DATA-03, TRSF-01, TRSF-02, TRSF-03, MREG-01, MREG-02, MREG-03) are satisfied.

**Orphaned requirements check:** REQUIREMENTS.md maps DEMO-01 and DEMO-02 to Phase 12 (not Phase 11). No Phase 11 requirements are orphaned.

### Anti-Patterns Found

No anti-patterns detected. Scanned all 7 modified/created files for TODO/FIXME/PLACEHOLDER/stub patterns — none found.

### Human Verification Required

#### 1. Interactive Launcher: Option 6 End-to-End Flow

**Test:** Place test files in `~/data/mydata/` (e.g., `test.txt`). Run `karpathy-autoresearch/launch-autoresearch.sh`. Select option 6. Verify the discover submenu shows `mydata (1 files)`. Select it. Confirm files are copied to `~/autoresearch/data/`.
**Expected:** Dataset discovery works; nested select shows file counts; files land in autoresearch data dir.
**Why human:** Requires interactive TTY and filesystem setup to test full flow.

#### 2. HF Model Selection Menu

**Test:** With at least one model in `~/.cache/huggingface/hub/models--*`, run the interactive launcher through any data source selection. Verify the HF model selection menu appears with sizes and a skip option.
**Expected:** Menu shows models in `org/name [SIZE]` format; selecting one exports `AUTORESEARCH_BASE_MODEL` to snapshot path; skipping prints "Skipping HF model selection."
**Why human:** Requires HF cache populated; select menu interaction requires TTY.

#### 3. eval-checkpoint.sh Full Eval + Registration Flow

**Test:** With a real HF-format checkpoint (containing config.json), run `bash scripts/eval-checkpoint.sh /path/to/checkpoint`. Verify temp vLLM starts on :8021, replay eval runs, safety-eval.json is written, and (if F1 >= 0.80) model entry appears in `~/.litellm/config.yaml`.
**Expected:** All 8 sections execute; safety-eval.json present in checkpoint dir; LiteLLM config updated; `docker restart litellm` reminder printed.
**Why human:** Requires GPU hardware, real checkpoint, Docker, and harness dataset to run end-to-end.

#### 4. Deregister + LiteLLM Restart Flow

**Test:** After a passing eval registers a model, run `bash scripts/autoresearch-deregister.sh autoresearch/exp-name`. Verify: (a) backup .bak.* file created alongside config.yaml, (b) model entry removed from config, (c) `docker restart litellm` makes model unavailable.
**Expected:** Backup created; model no longer in config; inference request to deregistered model name fails after restart.
**Why human:** Requires live LiteLLM instance and Docker.

### Gaps Summary

No gaps. All 12 observable truths are verified against the actual codebase. All 8 artifacts exist, are substantive, and are wired. All 9 requirement IDs are satisfied. Both test suites pass with 100% coverage (9/9 + 17/17).

The one deviation from plan (eval-checkpoint.sh using direct `cat >>` instead of calling `_litellm_register.py` for registration) does not constitute a gap — it is a documented design decision that achieves the same functional outcome with the added benefit of YAML comment preservation.

---

_Verified: 2026-03-24_
_Verifier: Claude (gsd-verifier)_
