# Project Research Summary

**Project:** DGX Toolbox v1.1 — AI Safety Harness
**Domain:** FastAPI gateway with NeMo Guardrails, Constitutional AI critique, eval harness, and red-teaming pipeline on DGX Spark (aarch64)
**Researched:** 2026-03-22
**Confidence:** MEDIUM (stack HIGH; streaming/CAI latency MEDIUM; aarch64 NeMo compatibility needs on-host verification)

## Executive Summary

This is a safety-harness service that sits in front of an existing LiteLLM proxy, adding layered defense: input guardrails (content filtering, PII redaction, prompt injection detection), post-model output rails (toxicity, jailbreak), a Constitutional AI two-pass self-critique loop, and an eval/red-team feedback stack. The canonical approach is a single FastAPI service that imports NeMo Guardrails as a library (not a sidecar), calls LiteLLM over HTTP for all model inference, and writes structured JSONL traces that feed the eval harness and red-team generator. This architecture is additive — no existing bash scripts, LiteLLM config, or model serving components are modified.

The recommended stack is well-validated for x86_64 but carries one firm hardware risk: NeMo Guardrails' `annoy` C++ dependency may not have pre-built aarch64 wheels, requiring on-host verification before any code is written. Everything else (FastAPI, httpx, presidio, lm-eval, garak, deepteam, Celery, SQLModel) is either pure Python or has confirmed aarch64 wheels. The Constitutional AI critique loop and streaming guardrails are architecturally sound but introduce latency complexity: CAI doubles or triples model calls per request, and streaming guardrails require thread-pool offloading to avoid event-loop starvation. Both must be designed for async-first operation from the start, not retrofitted.

The key risks are: (1) NeMo's `LLMRails` must be instantiated before the uvicorn event loop starts — initializing it inside an async handler causes a race condition that only manifests on the first request; (2) uvloop must be excluded because `nest_asyncio` (NeMo's async patch) cannot wrap uvloop's C extension; (3) trace logs containing raw PII are a compliance failure if written without a redaction pass; (4) Unicode normalization must precede every classifier or guardrail evasion via zero-width characters achieves 100% success. All four of these must be addressed in Phase 1 before the safety logic is layered on top.

## Key Findings

### Recommended Stack

The service runs Python 3.12 on aarch64 under FastAPI 0.135.1 with uvicorn (default asyncio loop — no uvloop). NeMo Guardrails 0.21.0 is imported as an in-process library, not a sidecar. The CAI critique loop is implemented as a plain async function calling LiteLLM via httpx 0.28.1. Structured traces go to SQLite via SQLModel 0.0.37. Red-team jobs run asynchronously via Celery 5.6.2 + Redis. The eval layer uses lm-eval 0.4.11 (pointed at the gateway for generative tasks, at LiteLLM directly for loglikelihood tasks) and a custom pytest-based replay harness.

See [STACK.md](./STACK.md) for full version table, installation commands, and the "What NOT to Use" list (avoid: python-jose, LangChain ConstitutionalChain, synchronous requests library, transformers inside the gateway).

**Core technologies:**
- Python 3.12 + FastAPI 0.135.1: async gateway with native SSE streaming and Pydantic v2 validation
- NeMo Guardrails 0.21.0: in-process Colang 2.0 input/output rails (requires `build-essential` for Annoy on aarch64)
- presidio-analyzer 2.2.362: PII detection and redaction (pure Python, aarch64-safe)
- httpx 0.28.1: async client for all outbound calls to LiteLLM (CAI judge calls, model calls)
- structlog 25.5.0 + SQLModel 0.0.37: structured JSON traces to SQLite
- lm-eval 0.4.11: capability benchmarks via OpenAI-compatible endpoint
- garak 0.14.0 + deepteam 1.0.6: one-shot scanning and feedback-loop red teaming
- Celery 5.6.2 + Redis 7.x: async dispatch of red-team jobs
- PyJWT 2.12.1 + slowapi: per-tenant auth and in-memory rate limiting (upgrade to fastapi-limiter + Redis for multi-worker)
- uv + ruff + mypy + pre-commit: dev toolchain

### Expected Features

See [FEATURES.md](./FEATURES.md) for full prioritization matrix and feature dependency graph.

**Must have (P1 — v1.1 core):**
- POST /v1/chat/completions — OpenAI-compatible pipeline endpoint
- Auth at ingress (API key + per-tenant policy profile) and rate limiting
- NeMo Guardrails input rails: content filter, PII detection, prompt injection detection
- NeMo Guardrails output rails: toxicity filter, jailbreak detection
- Constitutional AI two-pass self-critique with configurable judge model
- User-editable constitution (YAML, validated on startup)
- Configurable per-rail thresholds and enable/disable flags
- Refusal calibration: hard block / soft steer / informative refusal modes
- Full structured trace logging (JSONL, append-only, request_id indexed)

**Should have (P2 — add after core validated):**
- Custom replay eval harness against POST /chat (safety regression)
- lm-eval-harness integration for capability regression
- CI/CD eval gate (fail on safety F1 drop or over-refusal spike)
- Judge-guided guardrail threshold suggestions from trace history

**Defer (P3 — v1.1 advanced):**
- Streaming guardrails with per-N-token evaluation (NeMo streaming on aarch64 unverified; adds architectural complexity)
- Distributed live red teaming (requires stable trace logs, eval harness, and judge model first)
- Human-in-the-loop review dashboard (optional per PROJECT.md; high UI cost)
- Feedback loop into threshold calibration and fine-tuning data export

**Anti-features (never build):**
- Auto-apply guardrail threshold updates without human review
- Automated fine-tuning on harness-generated refusals without curation
- Synchronous blocking guardrail check on every streaming token
- Web UI for constitution/policy editing (config files + git is the right model)

### Architecture Approach

The gateway is a FastAPI service on port 8080 that orchestrates a sequential five-stage pipeline: auth/rate-limit → NeMo input rails → LiteLLM model call → NeMo output rails → CAI critique (optional) → async trace write. NeMo Guardrails is imported in-process (not a sidecar). Every request writes a structured JSONL trace to a host-mounted volume. The eval harness and red-team generator consume that trace store. The HITL dashboard (optional, port 8501) reads the same store. Nothing in the existing LiteLLM/vLLM/Ollama stack is modified.

See [ARCHITECTURE.md](./ARCHITECTURE.md) for full diagrams, component boundary table, data flow for streaming/eval/red-team paths, and a 13-step suggested build order.

**Major components:**
1. FastAPI gateway (`gateway/`) — HTTP surface, pipeline orchestrator, auth, rate-limit
2. NeMo Guardrails engine (`guardrails/`) — Colang 2.0 input/output rail evaluation, user-editable policies
3. CAI critique module (`critique/`) — two-pass generate → critique → revise, user-editable constitution
4. Trace store (`tracing/`) — append-only JSONL, async fire-and-forget write
5. Custom replay eval harness (`eval/`) — safety regression, lm-eval integration, CI gate
6. Red team generator (`red_team/`) — mines trace failures, generates adversarial variants
7. HITL dashboard (`dashboard/`) — optional Gradio review UI

### Critical Pitfalls

See [PITFALLS.md](./PITFALLS.md) for full details, recovery strategies, and a "looks done but isn't" verification checklist.

1. **LLMRails initialized inside async context** — instantiate `LLMRails` at module top level before `uvicorn.run()`, never inside a FastAPI startup hook or route handler. First-request-only symptom makes it easy to miss in testing.

2. **uvloop breaks NeMo Guardrails** — `nest_asyncio` cannot patch uvloop's C extension; service crashes on startup. Never install uvloop in the harness process. Pin `asyncio` event loop explicitly in the uvicorn launch command.

3. **Annoy aarch64 build failure** — NeMo Guardrails' C++ dependency may have no pre-built arm64 wheel. Validate `pip install nemoguardrails` on the DGX Spark in a fresh venv before writing any application code. Install `build-essential` first.

4. **Unicode injection bypasses all classifiers** — zero-width characters and homoglyphs achieve 100% evasion (arxiv 2504.11168). Add NFC/NFKC normalization + zero-width character stripping as the first preprocessing step before any guardrail classifier runs.

5. **Trace logs storing raw PII** — log the trace record only after the PII redaction pass, not before. Raw traces with user-submitted PII are a compliance failure. This is a Phase 1 design decision, not a Phase 3 retrofit.

6. **Synchronous CAI critique blocks responses** — constitutional AI adds 2–3 full inference round trips. For interactive use, run critique as an async background task after returning the response; enforce a hard timeout (10s) for any synchronous critique path.

7. **Colang version conflict** — Colang 2.0 is a complete language rewrite from 1.0; mixing syntax silently produces rails that do nothing. Pin `colang_version: "2.x"` in `config.yaml` on day one.

## Implications for Roadmap

Based on the combined research, the phase structure is driven by three dependency constraints: (1) the aarch64 environment must be validated before any code is written, (2) the core pipeline must be working before any feedback feature is built on top, and (3) trace logging must be producing real data before eval, red-teaming, or calibration can work.

### Phase 1: Environment and Gateway Foundation

**Rationale:** The highest-risk dependency (NeMo Guardrails on aarch64) must be validated before any other work. The asyncio/uvloop patterns and venv invocation conventions established here are load-bearing for all subsequent phases. Three critical pitfalls (LLMRails init, uvloop, Annoy build) must be resolved here, not discovered in Phase 2.

**Delivers:** Working Docker container with NeMo Guardrails installed on aarch64; passthrough FastAPI gateway on :8080 forwarding to LiteLLM :4000; structlog middleware; async JSONL trace writer with PII redaction pipeline; API key auth; in-memory rate limiting; verified latency baseline vs. direct LiteLLM.

**Addresses:** POST /chat endpoint, auth at ingress, rate limiting, full trace logging

**Avoids:** LLMRails async init conflict, uvloop incompatibility, Annoy build failure, double-proxy latency, venv activation in systemd, PII in raw traces (design the redaction pipeline here before guardrails are wired)

### Phase 2: Input and Output Guardrails

**Rationale:** Guardrails are the core product value. Build after the gateway foundation is proven. Unicode normalization must be added at the start of this phase, not as a follow-up. Pin Colang version immediately. Build input rails first (lower complexity), then output rails.

**Delivers:** NeMo Guardrails input rails (content filter, PII detection + redaction via presidio, prompt injection detection); NeMo output rails (toxicity, jailbreak); user-editable per-rail policy YAML with thresholds and enable/disable flags; refusal calibration modes (hard block / soft steer / informative); Unicode normalization preprocessing.

**Addresses:** Input content filtering, PII detection, prompt injection detection, output toxicity, jailbreak detection, configurable thresholds, refusal calibration

**Avoids:** Colang version conflict, Unicode injection evasion, streaming event loop blocking (defer streaming path to Phase 3+)

### Phase 3: Constitutional AI Critique

**Rationale:** Depends on a working output pipeline (Phase 2) and a functioning trace store (Phase 1). Must be designed async-first: critique runs as a background task for interactive requests, with a hard timeout for any synchronous path. Per-principle enable/disable flags must be in place from the start to avoid 3x GPU load on every request.

**Delivers:** Two-pass critique pipeline (generate → judge critique → revise); user-editable constitution YAML; configurable judge model (default: same model via LiteLLM); async/sync split with hard timeout; per-principle enable/disable; critique results written to trace records.

**Addresses:** Constitutional AI self-critique, user-editable constitution, judge-model configurability

**Avoids:** Synchronous critique unbounded latency, monolithic constitution (all principles on all requests)

### Phase 4: Eval Harness and CI Gate

**Rationale:** Eval depends on real trace data from Phase 1–3. This is the inflection point where the project shifts from "does it work" to "does it stay working." Build replay eval first (uses existing traces), then lm-eval integration (two-line config), then CI gate.

**Delivers:** Custom replay eval harness (JSONL prompt dataset → POST /chat → safety metrics); lm-eval-harness config pointing at gateway for generative tasks and LiteLLM for loglikelihood tasks (routed separately to avoid wrong scores); CI/CD promotion gate (fail on safety F1 regression or over-refusal spike).

**Addresses:** Custom replay eval harness, lm-eval-harness integration, CI/CD eval gate

**Avoids:** lm-eval chat endpoint wrong loglikelihood scores (explicit routing split), over-refusal invisible in metrics (track as first-class CI metric)

### Phase 5: Red Teaming

**Rationale:** Requires stable traces (Phase 1), eval harness (Phase 4), and judge model (Phase 3). The red-team generator mines trace failures for adversarial variants — without real failure data, it has no signal. Dataset balance policy must be enforced in code before the first feedback loop is enabled.

**Delivers:** Red-team generator that mines traces for failure patterns; adversarial prompt queue (JSONL) for human review before promotion to eval datasets; Celery + Redis async dispatch for long-running garak scans and deepteam sessions; dataset balance enforcement (adversarial ratio cap in code, not documentation).

**Addresses:** Distributed live red teaming from past critiques/evals/logs

**Avoids:** Red-team feedback loop creating skewed training data (balanced dataset policy, over-refusal CI gate), red-team prompts routed through gateway (generator calls LiteLLM directly)

### Phase 6: HITL Dashboard (Optional)

**Rationale:** Optional per PROJECT.md. Only worth building after trace volume justifies human review. Depends on all previous phases. Gradio is the right technology choice (no frontend build step, handles file reads and form controls natively).

**Delivers:** Gradio review UI on :8501; operator review queue (prioritized by borderline scores, not insertion order); annotation corrections written to corrections store; one-click policy threshold adjustment with diff view + confirmation; adversarial prompt promotion to eval datasets.

**Addresses:** Human-in-the-loop review dashboard, feedback loop into threshold calibration

**Avoids:** HITL review queue overload (priority sort), AI suggestions accepted without review (diff + confirmation required)

### Phase Ordering Rationale

- Phase 1 before all others because aarch64 compatibility is a binary gate and the asyncio/uvloop conventions are load-bearing.
- Phase 2 before Phase 3 because the constitutional critique evaluates model output that has already passed output guardrails — wiring them in reverse produces a worse safety posture during development.
- Phase 4 before Phase 5 because red-teaming requires an eval harness to measure attack success rate.
- Phase 6 last because it consumes all other phases' outputs and is explicitly optional.

The architecture's own build order recommendation (ARCHITECTURE.md, Steps 1–13) is consistent with this phase structure and should be followed within each phase.

### Research Flags

Phases likely needing deeper research during planning:

- **Phase 2 (Streaming guardrails path):** NeMo Guardrails streaming behavior on aarch64 is unverified. Streaming is deferred to P3 in FEATURES.md, but the non-streaming path's thread-pool offloading pattern for synchronous classifiers needs validation against actual NeMo action definitions on this hardware. Recommend a `/gsd:research-phase` for streaming guardrails when the P3 feature is planned.
- **Phase 3 (CAI latency budget):** The judge model's P95 latency on DGX Spark aarch64 with a local 7B model is unknown. Benchmark before designing the async/sync split — the right timeout value depends on actual hardware numbers. Verify before committing the Phase 3 plan.
- **Phase 5 (deepteam feedback loop):** deepteam 1.0.6 was released March 2026 and is relatively new. The feedback-loop red-teaming pattern (generating adversarial prompts from historical failure logs) is research-frontier territory. Plan this phase with a research step.

Phases with standard patterns (skip research-phase):

- **Phase 1 (Gateway foundation):** FastAPI + uvicorn + structlog + SQLModel are well-documented. The pitfalls are known and preventable with explicit checklist items. No novel integration patterns.
- **Phase 4 (Eval harness):** lm-eval-harness OpenAI-compatible endpoint integration is documented by EleutherAI and LiteLLM. The loglikelihood vs. generative endpoint routing split is a known gotcha with a clear fix. Standard pytest patterns for replay harness.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | All packages verified on PyPI with aarch64 compatibility notes. One confirmed risk: Annoy wheels on aarch64 — must verify on DGX Spark before committing to this path. |
| Features | MEDIUM | Table-stakes features (P1) are well-documented in NeMo and FastAPI ecosystems. Differentiators (CAI, streaming guardrails, red-teaming feedback loop) have academic backing but limited production case studies on local hardware. |
| Architecture | MEDIUM | Core FastAPI + NeMo library pattern is HIGH confidence. ARM64 NeMo compatibility and streaming guardrail internals are MEDIUM — require on-host validation. |
| Pitfalls | HIGH | NeMo-specific pitfalls (asyncio, uvloop, Colang versions) verified against official GitHub issues. Unicode evasion backed by arxiv 2504.11168. Integration gotchas verified against official docs. |

**Overall confidence:** MEDIUM

### Gaps to Address

- **NeMo Guardrails aarch64 install:** Run `pip install nemoguardrails` in a fresh venv on the DGX Spark before Phase 1 planning is finalized. If Annoy build fails, evaluate building from source in the Docker container using the upstream aarch64 Dockerfile.
- **Judge model latency on local hardware:** Benchmark a 7B model on DGX Spark aarch64 before committing to the CAI critique architecture in Phase 3. The async/sync split and timeout values depend on this number.
- **NeMo streaming on aarch64:** Defer streaming guardrails to Phase 3+ and validate NeMo's `chunk_size` streaming API on the actual hardware before planning that phase.
- **Port 8080 conflict:** ARCHITECTURE.md notes port 8080 is used by code-server (not launched by default). Confirm code-server is not running in the target deployment before assigning 8080 to the gateway.
- **lm-eval loglikelihood routing:** Verify that the completion endpoint (`:4000`) returns log-probabilities for the target model — vLLM supports this; Ollama's completion endpoint behavior for log-probs needs confirmation on this deployment.

## Sources

### Primary (HIGH confidence)

- [NeMo Guardrails PyPI](https://pypi.org/project/nemoguardrails/) — version 0.21.0, Python 3.10–3.13, C++ build requirements
- [NeMo Guardrails Installation Guide](https://docs.nvidia.com/nemo/guardrails/latest/getting-started/installation-guide.html) — aarch64 compiler requirements
- [NeMo Guardrails Streaming docs](https://docs.nvidia.com/nemo/guardrails/latest/user-guides/advanced/streaming.html) — chunk_size, context_size, stream_first
- [FastAPI PyPI](https://pypi.org/project/fastapi/) — v0.135.1, Pydantic v2 requirement
- [lm-evaluation-harness releases](https://github.com/EleutherAI/lm-evaluation-harness/releases) — v0.4.11
- [LiteLLM + lm-eval tutorial](https://docs.litellm.ai/docs/tutorials/lm_evaluation_harness) — OpenAI-compat endpoint integration
- [garak PyPI](https://pypi.org/project/garak/) — 0.14.0, Python 3.10–3.12
- [deepteam PyPI](https://pypi.org/project/deepteam/) — 1.0.6
- [SQLModel PyPI](https://pypi.org/project/sqlmodel/) — 0.0.37
- [NeMo Guardrails GitHub Issue #137](https://github.com/NVIDIA/NeMo-Guardrails/issues/137) — LLMRails async init conflict (verified)
- [NeMo Guardrails GitHub Issue #112](https://github.com/NVIDIA-NeMo/Guardrails/issues/112) — uvloop incompatibility (verified)
- [Constitutional AI NVIDIA docs](https://docs.nvidia.com/nemo-framework/user-guide/24.09/modelalignment/cai.html) — two-pass pipeline
- [lm-evaluation-harness API guide](https://github.com/EleutherAI/lm-evaluation-harness/blob/main/docs/API_guide.md) — loglikelihood vs. generative eval modes

### Secondary (MEDIUM confidence)

- [NVIDIA Blog: Stream Smarter and Safer](https://developer.nvidia.com/blog/stream-smarter-and-safer-learn-how-nvidia-nemo-guardrails-enhance-llm-output-streaming/) — streaming architecture internals
- [arxiv 2504.11168](https://arxiv.org/abs/2504.11168) — Unicode character injection achieves 100% guardrail evasion
- [arxiv 2212.08073](https://arxiv.org/abs/2212.08073) — Constitutional AI: Harmlessness from AI Feedback (Anthropic)
- [OWASP LLM Top 10 2025](https://cycode.com/blog/the-2025-owasp-top-10-addressing-software-supply-chain-and-llm-risks-with-cycode/) — prompt injection as #1 LLM vulnerability
- [NeMo Guardrails Colang 2.0 What's Changed](https://docs.nvidia.com/nemo/guardrails/latest/colang-2/whats-changed.html) — Colang 2.0 breaking changes
- [Existing codebase ARCHITECTURE.md](/.planning/codebase/ARCHITECTURE.md) — existing service ports, Docker patterns (first-party)

### Tertiary (LOW confidence)

- [Refusal Steering arXiv 2512.16602](https://arxiv.org/html/2512.16602) — refusal calibration patterns (needs validation against NeMo specifics)
- [C-SafeGen OpenReview](https://openreview.net/pdf/dfd7ac77a247ef06493d1b66dd3565ffedb70b24.pdf) — streaming guardrail patterns (academic, not production-validated)
- [Automatic LLM Red Teaming arXiv 2508.04451](https://arxiv.org/abs/2508.04451) — feedback-loop red teaming architecture (research frontier)

---
*Research completed: 2026-03-22*
*Ready for roadmap: yes*
