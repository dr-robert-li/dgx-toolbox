# GSD Debug Knowledge Base

Resolved debug sessions. Used by `gsd-debugger` to surface known-pattern hypotheses at the start of new investigations.

---

## harness-replay-429-rate-limit — Safety harness replay eval 429s despite high RPM/TPM config
- **Date:** 2026-03-23
- **Error patterns:** 429 Too Many Requests, 404 Not Found, rate limit, TPM, sliding window, replay eval, httpx ReadTimeout, timeout, retry exhausted, metrics wrong, precision recall F1 garbage
- **Root cause:** Four compounding bugs: (1) TPM gate used `>` not `>=` allowing one extra request at exact limit; (2) retry backoff max 31s insufficient against 60s window so all retries exhausted before TPM drained; (3) metrics.py had no "error" action — transport failures were misclassified as "allow" poisoning all scores; (4) httpx default timeout caused ReadTimeout crash on slow shared-GPU inference (>60s).
- **Fix:** sliding_window.py `> tpm_limit` → `>= tpm_limit`; replay.py retry schedule [2,4,8,16,65]s, add 404/502/503 to retry set, explicit "error" classification, httpx timeout=180s with ReadTimeout catch-and-retry; metrics.py add error_cases counter with `continue` skip in scoring loop; __main__.py print error_cases warning.
- **Files changed:** harness/ratelimit/sliding_window.py, harness/eval/replay.py, harness/eval/metrics.py, harness/eval/__main__.py, harness/tests/test_ratelimit.py, harness/tests/test_eval_replay.py
---

