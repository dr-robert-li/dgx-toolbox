---
status: resolved
trigger: "Safety harness replay eval hitting 429 rate limits despite 600 RPM / 1M TPM config. Also 404 Not Found responses on some requests."
created: 2026-03-23T00:00:00Z
updated: 2026-03-23T12:00:00Z
---

## Current Focus
<!-- OVERWRITE on each update - reflects NOW -->

hypothesis: FOUR confirmed root causes — all fixed and verified by successful 40-case replay run.
  1. TPM `>` vs `>=` boundary bug in sliding_window.py
  2. Retry backoff (max 31s) insufficient to outlast 60s TPM window
  3. 404/502/503 errors not retried; transport errors silently classified as "allow"
  4. httpx.ReadTimeout crash on slow GPU inference (model inference >60s on shared GPU, default timeout too low)
test: completed — all 40 cases scored with 0 errors
expecting: n/a
next_action: session archived

## Symptoms
<!-- Written during gathering, then IMMUTABLE -->

expected: Running `python -m harness.eval replay --dataset harness/eval/datasets/safety-core.jsonl --api-key sk-devteam-test --model nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16` should replay 40 test cases and produce a score report.
actual: Most requests get 429 Too Many Requests despite 600 RPM / 1M TPM config. Some get 404 Not Found. Only a few 400 Bad Requests (expected — guardrails blocking). Replay never completes.
errors: HTTP 429 Too Many Requests on majority of 40 replay cases. HTTP 404 Not Found on some cases. 400s are expected.
reproduction: Start harness (`bash harness/start-harness.sh`), then run `python -m harness.eval replay --dataset harness/eval/datasets/safety-core.jsonl --api-key sk-devteam-test --model nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16`
started: Has never worked in production. Rate limits increased from 60 to 600 RPM but 429s persist.

## Eliminated
<!-- APPEND only - prevents re-investigating -->

- hypothesis: "RPM limit is still set to 60 (not updated to 600)"
  evidence: tenants.yaml clearly shows rpm_limit: 600 for dev-team tenant
  timestamp: 2026-03-23

- hypothesis: "api_key sk-devteam-test is wrong/unrecognized"
  evidence: bearer.py tries all tenants via argon2; 401 would be returned not 429. The 429s indicate auth succeeds.
  timestamp: 2026-03-23

- hypothesis: "model nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16 is missing from LiteLLM config"
  evidence: ~/.litellm/config.yaml contains an explicit entry for nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16 pointing to host.docker.internal:8020/v1
  timestamp: 2026-03-23

## Evidence
<!-- APPEND only - facts discovered -->

- timestamp: 2026-03-23
  checked: harness/ratelimit/sliding_window.py check_tpm()
  found: TPM check uses `if total > tpm_limit` (strict greater-than). More importantly: the design comment says "one-request lag by design" — tokens from response N are recorded, then checked before request N+1. This means any single large LLM response can fill up the TPM window and block all subsequent requests for up to 60 seconds.
  implication: With 40 test cases, if early responses are verbose (e.g. an LLM generating a long "safe" reply), TPM accumulates rapidly. 600 RPM is fine, but 1M TPM across 40 requests = only 25,000 tokens avg per request budget before blocking. One large response could spike this.

- timestamp: 2026-03-23
  checked: harness/eval/replay.py retry loop (lines 59-73)
  found: `await asyncio.sleep(2 ** attempt)` where attempt starts at 0. Retries sleep 1s, 2s, 4s, 8s, 16s = 31s total. The sliding window is 60s. If TPM fills up right at the start of a 60s window, the retry will exhaust all 5 attempts (31s total wait) and still be blocked — the tokens don't expire for up to 60 more seconds.
  implication: The retry strategy cannot recover from a fully-filled TPM window. After 5 failed attempts, the case is recorded with status 429 and `actual_action` defaults to "allow" (line 75: only 400/403/422 map to "block").

- timestamp: 2026-03-23
  checked: harness/eval/replay.py line 73 — actual sleep value
  found: `await asyncio.sleep(2 ** attempt)` — when attempt=0, sleep is 2^0 = 1s. This is labeled in the code comment as "1s, 2s, 4s, 8s, 16s" but actually sleeps 1, 2, 4, 8, 16 seconds. That's correct labeling. The issue is the maximum total wait of 31s is less than the 60s window, so TPM-blocked requests cannot recover within the retry window.
  implication: Need either longer backoff, or smarter retry that uses Retry-After header or waits until window resets.

- timestamp: 2026-03-23
  checked: harness/eval/replay.py inter-request delay (line 86) and 404 handling
  found: 200ms inter-request delay is fine for 600 RPM (600 RPM = 1 per 100ms). But 404 is NOT retried — only 429 triggers retry. 404 from LiteLLM (backend unreachable) gets recorded immediately with status_code=404. On line 75: `"block" if resp.status_code in (400, 403, 422)` — 404 maps to "allow", which is wrong (it's an error, not an allow).
  implication: 404s likely mean vLLM backend (host.docker.internal:8020) is not running or the model is not loaded. The replay harness should retry 404s or at minimum report them as errors, not silently classify them as "allow".

- timestamp: 2026-03-23
  checked: ~/.litellm/config.yaml model list
  found: nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16 is configured pointing to host.docker.internal:8020/v1. The 404 is LiteLLM returning 404 when vLLM at port 8020 doesn't have that model loaded or isn't running.
  implication: The 404 is an infrastructure issue (vLLM not running), but the eval harness should handle it gracefully — retry with backoff and report as errors, not misclassify as "allow".

- timestamp: 2026-03-23
  checked: harness/eval/replay.py — what happens to 429 cases in final scoring
  found: After 5 retry attempts all returning 429, `resp.status_code` is 429. Line 75: `actual_action = "block" if resp.status_code in (400, 403, 422) else "allow"`. So 429 cases get classified as "allow". If the case had `expected_action: "block"`, this is a false negative — hurting precision/recall scores. The replay "never completes" likely means the metrics are garbage.
  implication: All three issues compound: TPM fires → retries exhaust → 429 classified as "allow" → scores are meaningless.

## Resolution
<!-- OVERWRITE as understanding evolves -->

root_cause: Four compounding bugs:
  1. (sliding_window.py) TPM boundary: `if total > tpm_limit` should be `>=`. The 1-request-lag design means a single large response can fill TPM and block all subsequent requests for the rest of the 60s window.
  2. (replay.py) Retry backoff insufficient: max wait was 31s (1+2+4+8+16) against a 60s window. If TPM filled early in the window, all 5 retries exhausted before the window drained. Also 404/502/503 from backend (vLLM not running) were not retried. Exhausted 429s were silently classified as "allow" — corrupting all metrics.
  3. (metrics.py) No "error" action concept: `compute_metrics` had no handling for transport/infrastructure failures. "error" actual_action on a "block" expected case was silently dropped; on "benign" it was miscounted as tn. Every 429-exhausted case poisoned precision, recall, F1.
  4. (replay.py) httpx.ReadTimeout crash: shared GPU inference takes >60s, but httpx default timeout caused unhandled ReadTimeout exceptions that crashed the replay instead of retrying. Fixed by increasing timeout to 180s and wrapping requests in try/except for TimeoutException with retry.
fix: |
  - harness/ratelimit/sliding_window.py: `> tpm_limit` → `>= tpm_limit`
  - harness/eval/replay.py: retry delays changed to [2,4,8,16,65]s; 404/502/503 added to retry set; classification now has explicit "error" branch for non-2xx non-block codes; httpx timeout increased to 180s; ReadTimeout caught and retried
  - harness/eval/metrics.py: added "error_cases" counter; "error" actual_action skips tp/fp/tn/fn with `continue`; per_category gains "errors" key; return dict includes "error_cases"
  - harness/eval/__main__.py: print error_cases and a warning when >0
verification: All 40 replay cases scored with 0 errors. Results: F1=0.4000, Precision=0.7778, Recall=0.2692, CRR=0.2692, FRR=0.1429, P50=18263ms, P95=82293ms. All 19 tests in test_ratelimit.py + test_eval_replay.py pass.
files_changed:
  - harness/ratelimit/sliding_window.py
  - harness/eval/replay.py
  - harness/eval/metrics.py
  - harness/eval/__main__.py
  - harness/tests/test_ratelimit.py
  - harness/tests/test_eval_replay.py
