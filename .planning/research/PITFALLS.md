# Pitfalls Research

**Domain:** AI safety harness (FastAPI gateway + NeMo Guardrails + Constitutional AI + eval harness) added to existing bash-heavy DGX Spark toolbox
**Researched:** 2026-03-22
**Confidence:** HIGH for NeMo Guardrails specifics (verified against official docs and GitHub issues); MEDIUM for Constitutional AI latency and red teaming (WebSearch + official paper, limited production case studies); HIGH for integration/async pitfalls (official docs + multiple verified sources)

---

## Critical Pitfalls

### Pitfall 1: NeMo Guardrails LLMRails Initialized Inside Async Function

**What goes wrong:**
`LLMRails` is instantiated inside a FastAPI route handler or a `@app.on_event("startup")` async function. On the first request, a `RuntimeError: Cannot enter into task while another task is being executed` fires. Subsequent requests succeed, masking the bug during testing.

**Why it happens:**
NeMo Guardrails patches the global asyncio event loop via `nest_asyncio` at import time. This patching creates conflicts when `LLMRails` is constructed inside an async context that is already running under uvicorn's event loop. FastAPI's lifespan handler runs inside the same event loop, so even "startup" hooks hit this.

**How to avoid:**
Instantiate `LLMRails` at module top level (outside any coroutine) before `uvicorn.run()` is called. Use FastAPI's `lifespan` context manager if you need to delay initialization, but ensure `LLMRails()` is called synchronously before the async context begins. Add an integration smoke test that calls the gateway on startup and asserts no asyncio exceptions — do not rely on manual testing that misses the first-call-only symptom.

**Warning signs:**
- Error appears only on the first POST to `/chat` after a fresh server start, then disappears
- Traceback mentions `nest_asyncio`, `asyncio.run`, or `Cannot enter task` in NeMo internals
- Works fine in a plain Python script but fails under uvicorn

**Phase to address:**
Phase 1 (Gateway foundation) — the initialization pattern must be established before any guardrail features are added on top of it.

---

### Pitfall 2: NeMo Guardrails and uvloop Incompatibility

**What goes wrong:**
FastAPI is started with `uvloop` (common for performance) and NeMo Guardrails raises `Can't patch loop of type <class 'uvloop.Loop'>` on startup. The entire service fails to start.

**Why it happens:**
`nest_asyncio` cannot patch `uvloop.Loop` because uvloop's C extension does not expose the same hook points as the pure-Python asyncio event loop. NeMo Guardrails relies on `nest_asyncio` patching, so uvloop breaks the guarantee.

**How to avoid:**
Do not run the safety harness process with uvloop. Use the default asyncio event loop for the FastAPI gateway process. If performance requires uvloop elsewhere, run those as separate services. Document this explicitly in the service `Makefile` / startup script so future contributors don't "optimize" by adding uvloop.

**Warning signs:**
- `uvloop` appears in `requirements.txt` or is installed as a transitive dep
- Service crashes immediately at startup with a `nest_asyncio` error
- Works in a plain Python REPL but not under uvicorn

**Phase to address:**
Phase 1 (Gateway foundation) — pin loop type in the uvicorn startup command before NeMo is integrated.

---

### Pitfall 3: Annoy Build Failure on aarch64 (NeMo Guardrails Dep)

**What goes wrong:**
`pip install nemoguardrails` fails on the DGX Spark (aarch64) with an error building the `annoy` wheel. The package has no pre-built arm64 wheel on PyPI for the required version, so pip falls back to source compilation and fails if build tools are absent.

**Why it happens:**
NeMo Guardrails pulls in `annoy`, a C++ library for approximate nearest neighbor search. On aarch64, pre-built wheels may not exist for the exact version pinned. If `gcc`, `g++`, and `python3-dev` are not installed, the source build errors out with a misleading pip error.

**How to avoid:**
Before writing `requirements.txt`, verify the full install on the DGX Spark in a fresh venv:
```bash
sudo apt-get install -y gcc g++ python3-dev
pip install nemoguardrails --no-cache-dir
```
Pin `annoy` explicitly to a version with a known aarch64 wheel if available; otherwise include the build deps in the service setup script. Add a CI step that runs `pip install -r requirements.txt` on an aarch64 runner (or the DGX itself) as a gate.

**Warning signs:**
- `ERROR: Could not build wheels for annoy` in pip output
- Install succeeds on a developer's x86_64 laptop but fails on DGX Spark
- Missing `gcc` or `g++` in the base environment

**Phase to address:**
Phase 1 (Gateway foundation / environment setup) — validate the full install before writing any application code.

---

### Pitfall 4: Streaming Guardrails Block the Event Loop on CPU-Bound Rails

**What goes wrong:**
NeMo Guardrails output rails (toxicity classifier, PII detector) are synchronous classifiers running on CPU. When called inside an async streaming generator, they block the uvicorn event loop for the duration of the inference, causing all concurrent requests to stall. This shows up as high tail latency under load, not as errors.

**Why it happens:**
Developers integrate guardrail checks as inline `await` calls inside the streaming generator, but the underlying classifiers are synchronous and CPU-bound. FastAPI/asyncio cannot yield the loop back to other requests while a CPU-bound task is running without explicit offloading.

**How to avoid:**
Offload all synchronous guardrail model calls to a thread pool executor:
```python
result = await asyncio.get_event_loop().run_in_executor(
    thread_pool_executor, classifier.check, chunk
)
```
Or use NeMo Guardrails' own async rail definitions with explicit `async def` actions. Profile with `asyncio-linter` or add a linting rule that flags `time.sleep` and blocking calls in async code paths. Set a per-chunk timeout so a slow classifier does not starve the stream indefinitely.

**Warning signs:**
- P50 latency is fine but P99 spikes under 5+ concurrent requests
- `top` shows 100% CPU on a single core during streaming
- Adding `asyncio.sleep(0)` between chunks temporarily reduces latency (confirms loop starvation)

**Phase to address:**
Phase 2 (Streaming guardrails) — design async offloading before implementing the streaming pipeline.

---

### Pitfall 5: Double-Proxy Latency Accumulation (FastAPI Gateway + LiteLLM)

**What goes wrong:**
The safety harness adds a FastAPI gateway in front of LiteLLM, which is itself a FastAPI proxy. Every request now passes through two HTTP hops, two JSON serialization/deserialization cycles, two middleware stacks, and two logging pipelines. Measured LiteLLM proxy overhead is 12 ms median (P99: 43 ms). Adding the harness naively doubles this, plus adds guardrail latency on top.

**Why it happens:**
Each FastAPI + Starlette middleware layer adds overhead even before application logic runs. CORS middleware, auth middleware, and Prometheus instrumentation all add serialization and allocation cost. Teams add these without measuring baseline, then discover the overhead only after deployment.

**How to avoid:**
- Measure baseline latency through LiteLLM alone before adding the harness.
- For the harness's internal call to LiteLLM, use the LiteLLM Python SDK directly instead of an HTTP call when running co-located (removes one full HTTP round-trip).
- Keep middleware minimal: one auth check, no duplicate logging between harness and LiteLLM.
- Run health/readiness endpoints on a separate lightweight app so they don't contend with the guardrail pipeline.
- Document a latency budget per phase: e.g., harness overhead must be < 50 ms added to model TTFT.

**Warning signs:**
- Measured TTFT through the harness is more than 2x the measured TTFT through LiteLLM alone
- Prometheus traces show time disappearing in middleware before route handlers
- Logs show duplicate entries (both harness and LiteLLM logging the same request)

**Phase to address:**
Phase 1 (Gateway foundation) — establish the LiteLLM call pattern before any guardrail work begins.

---

### Pitfall 6: Guardrail Evasion via Unicode / Character Injection

**What goes wrong:**
Input guardrails pass a prompt as clean, but the model receives the prompt with zero-width characters, Unicode homoglyphs, or emoji tags that obfuscate the true intent. The classifier was trained on clean text, so it misses the attack. NeMo Guardrails' built-in classifiers are not immune to this.

**Why it happens:**
A 2025 empirical study (arxiv 2504.11168) demonstrated up to 100% evasion success against Azure Prompt Shield and Meta Prompt Guard using character injection. The root cause is that classifiers trained on clean natural language fail to normalize Unicode before classification.

**How to avoid:**
- Add a Unicode normalization step (NFC/NFKC + zero-width character stripping) as the first input preprocessing stage, before any guardrail classifier runs.
- Include adversarial Unicode examples in the red-team test suite from Phase 1.
- Treat guardrails as one layer of a defense-in-depth stack, not a complete solution.
- Subscribe to NeMo Guardrails release notes for classifier updates.

**Warning signs:**
- Red team can craft prompts that pass guardrails by inserting invisible characters
- Guardrail logs show "PASS" for prompts that visually contain harmful content
- lm-eval-harness results show safety scores that don't match manual inspection

**Phase to address:**
Phase 2 (Pre/post guardrails) — add normalization before implementing classifiers, not as a retrofit.

---

### Pitfall 7: Trace Logs Storing Raw PII / Prompts

**What goes wrong:**
Full trace logging is implemented as specified (prompt, tools, model outputs, guardrail decisions). The prompt contains user-submitted PII (names, emails, credentials). The trace log files grow on disk without access control or redaction. Any process that can read the log directory can read all historical conversations.

**Why it happens:**
"Log everything for auditability" is the right instinct, but teams implement it as raw JSON dumps without a redaction pass. The guardrail's PII detector runs on the model's output, not on the logged trace record itself.

**How to avoid:**
- Run the PII redaction pass on the trace record before writing to disk, not just on the model output.
- Store full traces in a separate restricted-access log store (not the same directory as application logs).
- Apply structured logging with explicit field-level redaction: mark fields as `[REDACTED]` before serialization.
- Add a log retention policy from the start — don't let raw traces accumulate indefinitely.
- For the replay eval harness, ensure replayed prompts from production logs have been through the redaction pipeline first.

**Warning signs:**
- Log files are world-readable or in a directory with broad group permissions
- Log entries contain email addresses, phone numbers, or API keys in plain text
- Replay harness inputs have never been through the PII pipeline

**Phase to address:**
Phase 3 (Trace logging) — redaction policy before the first production log write.

---

### Pitfall 8: Colang 2.0 vs 1.0 Syntax Conflict

**What goes wrong:**
Developer writes Colang 1.0 flow definitions (using `define user`, `define bot`, `execute` keyword). Installs a newer version of NeMo Guardrails that defaults to Colang 2.0, and the flows silently do nothing or raise cryptic parse errors. The migration tool exists but is not automatically invoked.

**Why it happens:**
Colang 2.0 is a complete language rewrite: the `define` and `execute` keywords are gone, flows must be explicitly activated (not active by default), and `await` replaces `execute`. Documentation examples mix versions. Teams copy examples from blog posts that predate 2.0.

**How to avoid:**
- Pick one Colang version at project start and pin it explicitly in `config.yaml`: `colang_version: "2.x"` or `"1.0"`.
- Use only official NeMo Guardrails docs examples matching the pinned version.
- Add a CI test that loads the Colang config and validates it parses without errors against the installed version.
- When upgrading NeMo Guardrails, check the CHANGELOG-Colang.md for breaking changes before running the migration tool.

**Warning signs:**
- Guardrails appear to be active in config but never trigger
- No errors on startup, but flows have no effect on model output
- GitHub Copilot / LLM autocomplete suggests `define user` syntax (training data predates Colang 2.0)

**Phase to address:**
Phase 2 (Pre/post guardrails) — establish Colang version pin before writing any flow files.

---

### Pitfall 9: Constitutional AI Self-Critique Adds Unbounded Latency

**What goes wrong:**
The two-pass Constitutional AI critique pattern (model generates response → judge model critiques → model revises) doubles or triples inference time for every request. At interactive use, this makes the system feel broken. Without a timeout, a slow judge model blocks the response indefinitely.

**Why it happens:**
Each critique pass is a full LLM inference. A 7B judge model can take 2-15 seconds per critique on local hardware. Two passes = 2x that. Teams prototype with fast cloud APIs then discover local inference latency in production.

**How to avoid:**
- Implement critique as an optional async background pass: return the original response immediately, then post a critique result to a side-channel (log, dashboard) if the response passed safety rails.
- For synchronous critique (blocking), enforce a hard timeout per pass (e.g., 10 seconds). If the judge times out, log the timeout and return the original response with a flag.
- Benchmark the judge model's P95 latency on the DGX Spark aarch64 hardware before designing the pipeline.
- For streaming responses, run the critique on the completed buffer after streaming ends, not blocking the stream.

**Warning signs:**
- TTFB (time to first byte) exceeds 30 seconds for interactive queries
- Users report the system appearing hung
- Judge model P99 latency is within 2x of the interactive patience threshold

**Phase to address:**
Phase 3 (Constitutional AI) — define the synchronous/async split before implementing the critique loop.

---

### Pitfall 10: lm-eval-harness Loglikelihood Tasks Fail Against Chat Endpoints

**What goes wrong:**
lm-eval-harness is pointed at the `/chat` gateway endpoint. MMLU, HellaSwag, and other multiple-choice tasks fail or return garbage scores because they rely on log-probability scoring (loglikelihood), which is only available from completion endpoints — not chat-completion endpoints.

**Why it happens:**
lm-eval-harness has two evaluation modes: loglikelihood (requires access to token log-probs) and generative (uses text output). Chat-completion APIs do not return log-probs. Mixing chat-format evaluation with loglikelihood tasks silently produces wrong results, not errors, so teams only notice during result analysis.

**How to avoid:**
- Use the `--apply_chat_template` flag with a completion endpoint (not chat endpoint) for loglikelihood tasks.
- Separate eval targets: point capability benchmarks (MMLU, ARC) at the direct LiteLLM completion endpoint, point safety/refusal evals at the `/chat` gateway.
- Document this split in the eval harness README so future phases don't silently route the wrong tasks.

**Warning signs:**
- MMLU accuracy is suspiciously uniform across models (all scoring ~25% = random)
- No errors in harness output, but results look wrong
- Using a `/chat` or `/v1/chat/completions` endpoint for loglikelihood tasks

**Phase to address:**
Phase 4 (lm-eval-harness integration) — set up endpoint routing before running any benchmarks.

---

### Pitfall 11: Python Service in Bash Repo — venv Not Activated in Cron / Sync Invocations

**What goes wrong:**
The FastAPI service is developed with an activated venv. The service's systemd unit, cron entry, or NVIDIA Sync invocation forgets to activate the venv or specify the full venv Python path. The service starts with the system Python, which lacks all the safety harness dependencies, and produces `ModuleNotFoundError: No module named 'nemoguardrails'` at runtime.

**Why it happens:**
This is the first Python component in a bash-heavy repo. The existing bash scripts on this repo have no venv management pattern. Developers activate the venv manually during development and forget it's not active in non-interactive invocation contexts.

**How to avoid:**
- Use absolute venv Python path in all non-interactive invocation contexts: `/path/to/harness/.venv/bin/python`, never bare `python3`.
- In the systemd unit file, set `ExecStart=/path/to/harness/.venv/bin/uvicorn ...` — do not use `Environment=PATH=...` as a workaround.
- Add a smoke test to the bash `lib.sh` pattern: a `check_harness_deps` function that calls `$HARNESS_PYTHON -c "import nemoguardrails"` and fails loudly if the venv is missing.
- Document the venv path in `CLAUDE.md` and the service README.

**Warning signs:**
- Service works when run manually as the user but fails in cron or systemd
- `ImportError` or `ModuleNotFoundError` in service logs
- `which python` inside the service process resolves to `/usr/bin/python3` not the venv

**Phase to address:**
Phase 1 (Gateway foundation) — the venv path convention must be established and tested before any other phases build on it.

---

### Pitfall 12: Red Team Feedback Loop Creates Skewed Training Data

**What goes wrong:**
The distributed red teaming system generates adversarial prompts from past critiques and eval failures. These adversarial prompts are fed back into threshold calibration and labeled as training data for fine-tuning. Over time the dataset becomes dominated by adversarial examples, making the model more likely to refuse benign edge cases (over-refusal) because benign prompts are underrepresented.

**Why it happens:**
Feedback loops in eval harnesses naturally amplify failures — failures get labeled, reprocessed, and emphasized. Without active sampling of benign traffic to balance the adversarial examples, the dataset distribution drifts.

**How to avoid:**
- Maintain a balanced dataset policy: for every adversarial example added, add at least one benign example from production traffic.
- Track over-refusal rate as a first-class metric alongside safety metrics in CI/CD gates. Block promotion if over-refusal exceeds the threshold.
- Apply stratified sampling in the red team loop: sample adversarial prompts from the long tail (novel attack patterns), not just the easiest-to-reproduce failures.
- Version the training data corpus alongside model checkpoints so drift is detectable.

**Warning signs:**
- Safety scores improve while helpfulness scores (on benign tasks) degrade over multiple eval cycles
- Users report the model refusing reasonable requests after a safety update
- Training data ratio of adversarial to benign exceeds 30%

**Phase to address:**
Phase 5 (Red teaming + feedback loop) — define dataset balance policy before the first feedback loop is enabled.

---

## Technical Debt Patterns

Shortcuts that seem reasonable but create long-term problems.

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Pointing lm-eval at the same `/chat` endpoint as users | Single endpoint to maintain | Silently wrong loglikelihood scores on all MC tasks | Never — route evals separately |
| Storing raw traces in application log dir | Zero extra infra | PII exposure, audit failure, no retention control | Never in production |
| Using LiteLLM HTTP call from harness instead of SDK | Simpler code | Extra HTTP hop, doubled latency overhead | Only in early prototype, remove before Phase 2 |
| Initializing LLMRails in a FastAPI startup hook (async) | Feels clean | asyncio/nest_asyncio conflict on first request | Never — initialize at module level |
| Skipping Unicode normalization on input, relying on classifier | Less code | 100% evasion success for Unicode injection attacks | Never |
| Running critique synchronously before returning response | Simpler mental model | Unacceptable TTFB on local hardware | Only for offline batch eval, never for interactive |
| Installing NeMo Guardrails system-wide instead of venv | One less step | Breaks existing system Python deps, conflicts between toolbox scripts and harness | Never — always use venv |
| Colang version left implicit (no `colang_version` pin) | Zero config | Silent migration issues when NeMo Guardrails is upgraded | Never |

---

## Integration Gotchas

Common mistakes when connecting to external services.

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| NeMo Guardrails + FastAPI | Constructing `LLMRails` inside an async handler | Construct at module top level before `uvicorn.run()` |
| NeMo Guardrails + uvicorn | Running uvicorn with `--loop uvloop` | Use default asyncio loop; uvloop cannot be patched by nest_asyncio |
| Harness gateway + LiteLLM | HTTP call from harness to LiteLLM for every request | Use LiteLLM Python SDK when co-located to avoid second HTTP hop |
| lm-eval-harness + gateway | Point all tasks at `/v1/chat/completions` | Route loglikelihood tasks to completion endpoint, generative to chat |
| Streaming + NeMo output rails | Call blocking classifier inline in async generator | Offload to `run_in_executor` thread pool |
| Trace logger + PII | Log raw prompt/response to JSON file | Run PII redaction pass before writing trace record |
| Red team loop + training data | Auto-label all adversarial examples, no benign sampling | Maintain balanced dataset policy, track over-refusal metric |
| FastAPI harness + Nginx/reverse proxy | SSE stream buffered by Nginx until 16KB | Add `X-Accel-Buffering: no` header to streaming responses |

---

## Performance Traps

Patterns that work at small scale but fail as usage grows.

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Blocking classifier in async stream path | High P99 latency, low P50 | Offload to thread pool executor | At 5+ concurrent streaming requests |
| LiteLLM Postgres log table unbounded growth | Slow query latency, dashboard hangs | Add log retention/pruning from day one | Past ~1M rows |
| Synchronous critique before stream return | Every request feels hung | Async critique or hard timeout | Immediately on local 7B+ judge model |
| Full trace stored in SQLite for replay harness | Replay harness slow to load test cases | Use append-only log files + indexed SQLite for metadata only | Past ~100K traces |
| Redis for usage-based routing between harness and LiteLLM | Added Redis round-trip per request | Use simple shuffle routing; reserve Redis for session state | At 50+ req/s |
| HITL dashboard loading all traces at once | Dashboard hangs | Paginate traces, filter by review status | Past ~10K unreviewed traces |

---

## Security Mistakes

Domain-specific security issues beyond general web security.

| Mistake | Risk | Prevention |
|---------|------|------------|
| No Unicode normalization before input classifier | 100% guardrail evasion via zero-width chars, homoglyphs | NFC/NFKC normalize + strip zero-width chars before any classifier |
| Logging raw prompts with PII before redaction | Compliance failure, credential exposure | PII redaction pass before trace write |
| Red team prompts fed back as training data without human review | Trains model to produce adversarial outputs | Human-in-loop review gate on any example entering fine-tune corpus |
| No rate limiting at harness ingress | Inference compute exhaustion, DoS via LLM cost | Token-bucket rate limiting per tenant/IP in Phase 1 |
| Trace replay harness reading production logs directly | Sensitive prod data exposed to CI environment | Anonymized/redacted log export pipeline for replay harness |
| Constitution file world-writable | Attacker modifies constitution to permit harmful output | Read-only mount for constitution and Colang config in production |
| Guardrail bypass treated as an anomaly, not an attack | Silent evasion goes undetected | Log all guardrail decisions and alert on unusual PASS rate spikes |

---

## UX Pitfalls

Common user experience mistakes in this domain (operator UX — the people tuning guardrails).

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Constitution editing with no preview/test | Operator changes a principle, does not see effect until next eval run | Add a `--dry-run` mode that runs the critique loop on a sample prompt immediately |
| Guardrail threshold UI with no baseline reference | Operator does not know what threshold 0.7 means in practice | Show example prompts that pass/fail at current threshold alongside the slider |
| HITL review queue shows all traces, no prioritization | Reviewer burns out on benign traces | Default to showing borderline-scored and flagged traces first |
| Over-refusal is invisible in dashboard | Operators optimize for safety metrics, helpfulness degrades silently | Surface over-refusal rate as a top-level metric next to safety score |
| AI-guided guardrail suggestions accepted with one click | Operator rubber-stamps AI suggestions without understanding change | Require diff view + confirmation comment for AI-suggested constitution changes |

---

## "Looks Done But Isn't" Checklist

- [ ] **NeMo Guardrails installed:** Verify `from nemoguardrails import LLMRails` imports without error on aarch64 before writing any integration code
- [ ] **Streaming guardrails:** Verify output rails are offloaded to thread pool — a passing test with a fast mock classifier does not prove it
- [ ] **Unicode normalization:** Verify the normalization step runs before classifiers, not after — add a test with a zero-width-character-injected prompt
- [ ] **Colang version pinned:** Verify `colang_version` is explicit in `config.yaml`, not relying on NeMo default
- [ ] **LLMRails initialization:** Verify it is called before `uvicorn.run()`, with a test that hits the endpoint twice in quick succession (not just once)
- [ ] **Trace PII redaction:** Verify the redaction pipeline runs on trace records, not only on model output — inspect a raw trace file after a test with a synthetic PII prompt
- [ ] **lm-eval routing:** Verify loglikelihood tasks are hitting a completion endpoint by checking that MMLU scores are non-uniform (not ~25%)
- [ ] **venv in systemd:** Verify the service starts correctly via `systemctl start`, not just `python -m uvicorn ...` in the terminal
- [ ] **Over-refusal metric:** Verify the CI gate checks over-refusal rate, not only safety pass rate — run a benign prompt suite after every safety config change
- [ ] **Dataset balance:** Verify the red team feedback loop has a max adversarial ratio enforced in code, not as a documentation note

---

## Recovery Strategies

When pitfalls occur despite prevention, how to recover.

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| asyncio/LLMRails init conflict discovered in production | LOW | Move LLMRails construction to module level; redeploy; no data loss |
| uvloop incompatibility | LOW | Remove uvloop from requirements; restart service |
| Annoy build failure on aarch64 | LOW-MEDIUM | `apt-get install gcc g++ python3-dev` then rebuild venv; add to setup script |
| Trace logs containing raw PII already on disk | HIGH | Audit affected files; run redaction script over historical logs; rotate access credentials if any leaked; update retention policy |
| Colang 1.0 flows silently doing nothing under 2.0 | MEDIUM | Run `nemoguardrails convert`; test each flow; pin version going forward |
| Over-refusal from skewed training data | HIGH | Roll back constitution/thresholds to last known good; audit dataset balance; remove adversarial-only batches from corpus |
| lm-eval wrong scores from chat endpoint | LOW | Redirect loglikelihood tasks to completion endpoint; rerun benchmarks; discard contaminated historical scores |
| Streaming event loop starvation in production | MEDIUM | Add `run_in_executor` for all blocking classifiers; load test before re-enabling streaming |

---

## Pitfall-to-Phase Mapping

How roadmap phases should address these pitfalls.

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| LLMRails init in async context | Phase 1 (Gateway) | Smoke test: two rapid consecutive requests, assert no asyncio exceptions |
| uvloop incompatibility | Phase 1 (Gateway) | Verify `loop=asyncio` in uvicorn config; check `asyncio.get_event_loop().__class__.__name__` != `uvloop.Loop` |
| Annoy aarch64 build failure | Phase 1 (Env setup) | `pip install nemoguardrails` in fresh venv on DGX Spark; assert import works |
| Double-proxy latency | Phase 1 (Gateway) | Measure baseline TTFT through LiteLLM alone vs through harness; assert delta < 50 ms |
| Colang version conflict | Phase 2 (Guardrails) | Assert `colang_version` key exists in config.yaml; validate Colang parses on CI |
| Streaming event loop blocking | Phase 2 (Streaming) | Load test: 10 concurrent streaming requests; assert P99 TTFT < 2x single-request P99 |
| Unicode injection evasion | Phase 2 (Guardrails) | Red team test suite includes zero-width and homoglyph examples; assert all flagged |
| Trace PII logging | Phase 3 (Trace logging) | Unit test: send synthetic PII prompt; assert no PII in trace file on disk |
| Synchronous critique latency | Phase 3 (Constitutional AI) | Measure TTFB with and without critique; assert interactive mode is async |
| venv not activated in systemd | Phase 1 (Gateway) | Start service via `systemctl start`; assert `ModuleNotFoundError` does not occur |
| lm-eval chat endpoint wrong scores | Phase 4 (lm-eval) | Run MMLU; assert score is non-uniform (> 30% and variance across models) |
| Red team dataset drift | Phase 5 (Red teaming) | Enforce adversarial ratio cap in code; CI gate on over-refusal metric |
| HITL review queue overload | Phase 6 (Dashboard) | Default queue sorted by borderline score, not insertion order |

---

## Sources

- [NeMo Guardrails GitHub Issue #137: asyncio exception when initializing LLMRails inside function](https://github.com/NVIDIA/NeMo-Guardrails/issues/137)
- [NeMo Guardrails GitHub Issue #112: Can't patch loop of type uvloop.Loop](https://github.com/NVIDIA-NeMo/Guardrails/issues/112)
- [NeMo Guardrails Installation Guide — compiler requirements](https://docs.nvidia.com/nemo/guardrails/latest/getting-started/installation-guide.html)
- [NeMo Guardrails GitHub Issue #86: annoy wheel build failure](https://github.com/NVIDIA-NeMo/Guardrails/issues/86)
- [NeMo Guardrails Streaming docs](https://docs.nvidia.com/nemo/guardrails/user_guides/advanced/streaming.html)
- [NeMo Guardrails Colang 2.0 What's Changed](https://docs.nvidia.com/nemo/guardrails/latest/colang-2/whats-changed.html)
- [NVIDIA blog: Stream Smarter and Safer — streaming guardrails](https://developer.nvidia.com/blog/stream-smarter-and-safer-learn-how-nvidia-nemo-guardrails-enhance-llm-output-streaming/)
- [LiteLLM middleware performance blog](https://docs.litellm.ai/blog/fastapi-middleware-performance)
- [LiteLLM production best practices](https://docs.litellm.ai/docs/proxy/prod)
- [arxiv 2504.11168: Bypassing LLM Guardrails — character and AML evasion at up to 100% success](https://arxiv.org/abs/2504.11168)
- [Mindgard: Bypassing LLM guardrails in practice](https://mindgard.ai/resources/bypassing-llm-guardrails-character-and-aml-attacks-in-practice)
- [FastAPI event loop blocking case study (2026)](https://www.techbuddies.io/2026/01/10/case-study-fixing-fastapi-event-loop-blocking-in-a-high-traffic-api/)
- [FastAPI SSE streaming docs](https://fastapi.tiangolo.com/tutorial/server-sent-events/)
- [LiteLLM lm-evaluation-harness tutorial](https://docs.litellm.ai/docs/tutorials/lm_evaluation_harness)
- [lm-evaluation-harness API guide — loglikelihood vs generative](https://github.com/EleutherAI/lm-evaluation-harness/blob/main/docs/API_guide.md)
- [Statsig: PII redaction in LLMs](https://www.statsig.com/perspectives/piiredactionprivacyllms)
- [Langfuse: LLM security and guardrails trace logging](https://langfuse.com/docs/security-and-guardrails)
- [Kinde: Human-in-the-loop evals at scale](https://www.kinde.com/learn/ai-for-software-engineering/ai-devops/human-in-the-loop-evals-at-scale-golden-sets-review-queues-drift-watch/)
- [Braintrust: Best AI evals tools for CI/CD 2025](https://www.braintrust.dev/articles/best-ai-evals-tools-cicd-2025)
- [NeMo Guardrails nested asyncio loop docs](https://docs.nvidia.com/nemo/guardrails/0.16.0/user-guides/advanced/nested-async-loop.html)

---
*Pitfalls research for: AI safety harness (FastAPI + NeMo Guardrails + Constitutional AI + eval harness) on DGX Spark aarch64*
*Researched: 2026-03-22*
