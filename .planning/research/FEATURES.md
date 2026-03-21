# Feature Research

**Domain:** AI safety harness — FastAPI gateway wrapping open-source LLMs with guardrails, constitutional critique, evals, and human feedback
**Researched:** 2026-03-22
**Confidence:** MEDIUM (stack components well-documented; integration patterns emerging; some areas — streaming guardrails on aarch64, refusal calibration UX — have LOW confidence from single/unverified sources)

---

> **Milestone context:** This is v1.1 of the DGX Toolbox. v1.0 (tiered model storage) is already built.
> The safety harness is a new Python component that sits in front of the existing LiteLLM proxy.
> The existing FEATURES.md covered v1.0. This file covers v1.1 only.

---

## Feature Landscape

### Table Stakes (Users Expect These)

Features users assume exist in any production AI safety gateway. Missing these = harness feels like a toy or a security hole.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| POST /chat HTTP endpoint | Universal interface — every client (curl, LangChain, custom) expects a chat-compatible endpoint | LOW | FastAPI. OpenAI-compatible schema preferred so existing clients work without changes. Pipeline: input guardrails → model → post-guardrails → response. |
| Input content filtering (harmful/offensive topics) | Baseline safety: no production gateway ships without some input filter | MEDIUM | NeMo Guardrails Colang 2.0 input rails. Covers hate speech, violence, CSAM categories. Classifier-based (not regex). |
| Prompt injection detection | OWASP LLM Top 10 #1 vulnerability in 2025 — every gateway must address it | MEDIUM | NeMo Guardrails has built-in injection detection. Alternatively: separate classifier (Lakera Guard, or small fine-tuned model). Rule-based regex as fallback. |
| PII detection and redaction (input) | Legal compliance (GDPR, CCPA), enterprise requirement — PII in prompts reaching external or shared models is a liability | MEDIUM | NeMo Guardrails has PII rails. Pattern: detect → redact → pass sanitized prompt → un-redact in response. Spacy + presidio work well for named entity PII. |
| Output toxicity filtering | Users expect the gateway to prevent obviously harmful outputs from reaching clients | MEDIUM | NeMo output rails or Llama Guard 3 as a classifier. Flag or block responses above threshold. |
| Jailbreak detection (post-model) | Detect when a model was successfully manipulated into producing harmful output despite input guardrails | HIGH | Harder than input filtering — requires evaluating the output in context. LLM-as-judge pattern or fine-tuned classifier. |
| Full request/response trace logging | Observability is table stakes for any production service — operators need to audit what happened | MEDIUM | Structured JSON logs: timestamp, request_id, user, prompt, guardrail decisions, model output, latency, tokens. OpenTelemetry-compatible. Separate from application logs. |
| Configurable guardrail enable/disable | Operators need to tune the harness for their use case; hardcoded rails are not usable | LOW | Per-rail config flags in YAML/TOML. No UI required — config file. |
| Auth at ingress | Any shared gateway must authenticate callers to enforce per-tenant policies | LOW | API key auth via FastAPI middleware. Virtual key per user/team maps to a policy profile. LiteLLM already does this — harness can delegate to LiteLLM's key management or replicate a lightweight version. |
| Rate limiting | Prevents abuse and protects GPU resources — expected by any team sharing the gateway | LOW | FastAPI middleware or slowapi. Per API key rate limits. Configurable burst + sustained rates. |

### Differentiators (Competitive Advantage)

Features that make this harness more useful than NeMo Guardrails or LiteLLM alone. These are the reason to build a custom harness rather than using an off-the-shelf tool.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Constitutional AI two-pass self-critique | Model critiques its own response against user-defined principles before delivery — catches value misalignment that classifiers miss | HIGH | Two-pass: (1) model generates response, (2) judge model critiques against constitution, (3) revise or refuse if critique fails threshold. Configurable judge model (default: same model, swappable to a stronger judge). Adds 1-2 inference round trips per request. |
| User-editable constitutional principles | Most guardrail products hardcode principles; letting users define their own constitution makes the harness domain-adaptable | MEDIUM | Constitution stored as a YAML/text file. Versioned with git. Each principle is a natural-language statement. UI: text editor + validation script. Judge model can summarize how well current constitution covers observed failures. |
| User-tunable guardrail rules with judge-guided suggestions | Users can review which guardrails fired, adjust thresholds, and get AI-generated suggestions for improving rules based on observed false positives/negatives | HIGH | Per-rail threshold in config. Judge model analyzes recent trace logs and suggests threshold adjustments or new rules. Suggestions are human-readable, not auto-applied. Closes the loop between observed behavior and policy. |
| Refusal calibration (helpful refusal + soft steering) | Binary block/allow is too coarse — users want the model to redirect rather than refuse, and to tune how sensitive the refusal trigger is | HIGH | Three modes: hard block (stop), soft steer (redirect to safe paraphrase), informative refusal (explain why + suggest alternative). Threshold slider per guardrail. Over-refusal is a known 2025 research problem — calibration tooling is novel. |
| Streaming guardrails with per-N-token evaluation | Allows streaming responses while still applying safety checks — without this, guardrails force buffering, destroying streaming UX | HIGH | Evaluate every N tokens (configurable, default 128-256) for lightweight checks (PII, toxicity keywords). Full evaluation at end-of-stream for deeper checks. Redact or truncate retroactively if end-of-stream eval fails. NeMo Guardrails added streaming support in recent versions; verify on aarch64. |
| Custom replay eval harness against POST /chat | Operators can replay historical conversations against the live gateway to measure safety regressions — most harnesses have no built-in eval tooling | HIGH | Eval dataset (JSON) → replay against /chat → compare guardrail decisions vs expected labels → produce safety/refusal metrics (precision, recall, F1 per category). Run locally or in CI. |
| lm-eval-harness integration for capability benchmarks | Capability regression after tuning guardrails is real — need to verify model quality didn't degrade | MEDIUM | lm-eval-harness supports local endpoints via its API mode. Configure to hit /chat endpoint. Standard benchmarks: MMLU, HellaSwag, TruthfulQA. CI gate: block if benchmark delta > threshold. |
| CI/CD eval integration with promotion gate | Prevents shipping a guardrail config update that regresses safety or capability without human review | MEDIUM | GitHub Actions (or local CI): run replay eval + lm-eval on every PR to guardrail config. Fail if safety F1 drops or false positive rate rises above threshold. Configurable gates per metric. |
| Distributed live red teaming from past critiques/evals/logs | Automatically generates adversarial prompts from observed failure patterns — a feedback-driven attack surface that grows with usage | HIGH | Analyze trace logs + eval failures to extract failure patterns. Use judge model to generate adversarial variations. Run against /chat endpoint. Rank by attack success rate. Surface results for human review. PyRIT or custom orchestrator. This is research-frontier territory — novel for a local toolbox. |
| Human-in-the-loop review dashboard | Allows operators to review flagged outputs, correct labels, and feed corrections back into threshold calibration and fine-tuning data | HIGH | Web UI (lightweight — FastAPI + HTMX or a simple React page). Shows flagged traces, guardrail decisions, constitutional critique. Operator can approve/reject/relabel. Corrections stored in a labeled dataset. Optional: corrections trigger threshold recalibration. |
| Feedback loop into threshold calibration and fine-tuning data | Human corrections and eval results automatically inform guardrail threshold adjustments and produce a labeled dataset for future fine-tuning | HIGH | Labeled correction events → compute per-rail precision/recall at current threshold → suggest new threshold (Bayesian update or simple percentile). Export labeled dataset in SFT format (prompt, response, label). Does not auto-apply changes — always human-reviewed. |

### Anti-Features (Commonly Requested, Often Problematic)

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Auto-apply guardrail threshold updates | "Have the AI tune itself" — seems like closing the loop automatically | Creates runaway feedback: a miscalibrated judge lowers thresholds based on false-negative feedback, making the harness progressively less safe. Race condition between eval signal and real traffic. | Surface suggested thresholds as a PR diff for human review. Automate the suggestion, not the application. |
| Embedding guardrails into the model via fine-tuning (automated) | "Train the model to refuse by default" | Fine-tuning on harness-generated refusals without careful curation creates over-refusal (model refuses benign requests). This is the core problem the 2025 refusal calibration literature is trying to solve. | Use inference-time guardrails for control; fine-tuning data should be curated from human-reviewed corrections only. |
| Synchronous blocking guardrails on every token (full streaming block) | "Check every token for safety" | Per-token LLM-based evaluation adds O(N) round trips, making streaming unusable. Latency multiplies with response length. | Batch every N tokens (128-256) for lightweight checks; reserve full evaluation for end-of-stream. Redact retroactively if needed. |
| Web UI for policy / constitution editing | "WYSIWYG editor for guardrail rules" | Introduces auth, session management, CSRF, XSS surface area for what is essentially a config file editor. A CMS for a config file. | Policies are YAML/text files versioned in git. The judge model generates suggestions as text; operator applies with a text editor. This is explicitly out of scope in PROJECT.md. |
| Multi-tenant policy database with per-user rules | "Each user gets their own constitution" | Massive config management complexity. Per-user state in a database for what is currently a stateless gateway. Requires migrations, backups, conflict resolution. | Per-API-key policy profiles in config files. Each key maps to a named policy set. Cover 90% of multi-tenant needs without a database. |
| Real-time guardrail updates without restart | "Hot-reload policies without downtime" | Config hot-reload introduces race conditions between in-flight requests and new policy state. Silent policy drift is harder to audit than versioned deploys. | Versioned config files + fast restart (FastAPI starts in <1s). Canary deploy new policy to a secondary instance first. |
| Replacing LiteLLM with a custom model router | "The harness should also route models" | LiteLLM already handles routing, load balancing, and multi-provider support. Rebuilding this in the harness duplicates work and loses LiteLLM's ecosystem integrations. | Harness calls LiteLLM as the model backend. Model routing stays in LiteLLM. Harness is safety-only. |

## Feature Dependencies

```
[Auth at Ingress]
    └──gates──> [POST /chat endpoint] (unauthenticated requests rejected before pipeline)

[POST /chat endpoint]
    └──requires──> [Input Content Filtering]
    └──requires──> [PII Detection (input)]
    └──requires──> [Prompt Injection Detection]
    └──produces──> [Model Response]
    └──requires──> [Output Toxicity Filtering]
    └──requires──> [Jailbreak Detection (post-model)]
    └──produces──> [Trace Log Entry]

[Constitutional AI Self-Critique]
    └──requires──> [POST /chat pipeline] (critique runs post-model, pre-delivery)
    └──requires──> [User-Editable Constitutional Principles] (critique needs a constitution to evaluate against)
    └──enhances──> [Output Toxicity Filtering] (constitutional critique catches value misalignment classifiers miss)

[User-Tunable Guardrail Rules with Judge Suggestions]
    └──requires──> [Full Trace Logging] (judge reads trace history to make suggestions)
    └──requires──> [Configurable Guardrail Enable/Disable] (tuning means changing config)
    └──enhances──> [Constitutional AI Self-Critique] (same judge model can suggest constitution edits)

[Refusal Calibration]
    └──requires──> [Configurable Guardrail Enable/Disable] (threshold is a per-rail config value)
    └──requires──> [Full Trace Logging] (calibration evidence comes from observed decisions)
    └──enhances──> [Output Toxicity Filtering]
    └──enhances──> [Jailbreak Detection]

[Streaming Guardrails]
    └──requires──> [POST /chat endpoint with streaming mode]
    └──requires──> [Input Content Filtering] (lightweight checks adapted for streaming)
    └──requires──> [Output Toxicity Filtering] (adapted for partial buffers)
    └──conflicts──> [Synchronous full-evaluation per token] (latency incompatible)

[Custom Replay Eval Harness]
    └──requires──> [POST /chat endpoint] (replays hit live gateway)
    └──requires──> [Full Trace Logging] (eval compares against logged decisions)
    └──produces──> [Safety/Refusal Metrics]

[lm-eval-harness Integration]
    └──requires──> [POST /chat endpoint with OpenAI-compatible API] (lm-eval uses OpenAI client)
    └──produces──> [Capability Benchmark Results]

[CI/CD Eval Integration]
    └──requires──> [Custom Replay Eval Harness] (safety regression gate)
    └──requires──> [lm-eval-harness Integration] (capability regression gate)
    └──produces──> [Promotion Gate Pass/Fail]

[Distributed Live Red Teaming]
    └──requires──> [Full Trace Logging] (attack generation uses past failures as seeds)
    └──requires──> [Custom Replay Eval Harness] (generated attacks are evaluated via replay)
    └──requires──> [Constitutional AI Self-Critique] (judge model used to score attack success)
    └──enhances──> [Human-in-the-Loop Review Dashboard] (red team results surfaced for review)

[Human-in-the-Loop Review Dashboard]
    └──requires──> [Full Trace Logging] (dashboard reads trace store)
    └──requires──> [Custom Replay Eval Harness] (eval results surfaced in dashboard)
    └──produces──> [Labeled Correction Events]

[Feedback Loop into Threshold Calibration]
    └──requires──> [Human-in-the-Loop Review Dashboard] (corrections are the input signal)
    └──requires──> [Refusal Calibration] (threshold update is the output)
    └──requires──> [Full Trace Logging] (historical signal for calibration computation)
    └──produces──> [Fine-Tuning Dataset] (labeled export)
```

### Dependency Notes

- **POST /chat pipeline is the backbone.** Every other feature is either a pre-condition, a stage within, or an observer of this pipeline. It must be built first.
- **Full trace logging must be wired before eval, red teaming, or calibration.** Without logs, there is no signal for any feedback feature.
- **Constitutional AI requires a working judge model.** The judge model call adds latency; it should be configurable to skip in low-latency contexts.
- **Streaming guardrails conflict with full synchronous evaluation.** These are different operating modes, not the same feature. The harness must decide at request time which mode applies (streaming vs. non-streaming clients).
- **Human-in-the-loop dashboard is optional but gates the feedback loop.** Without human corrections, threshold calibration has no reliable input signal. Auto-calibration without human review is an anti-feature (see above).
- **Red teaming is the most dependent feature.** It requires logging, eval harness, and judge model. Do not start it until those are stable.
- **Existing infrastructure dependencies:** LiteLLM proxy (model backend), existing launcher scripts (not modified by harness), existing NVMe storage (models accessible at same paths).

## MVP Definition

### Launch With (v1.1 core)

Minimum viable harness — validates that the pipeline works end-to-end and safety checks run correctly before building the feedback/eval stack on top.

- [ ] FastAPI POST /chat endpoint with OpenAI-compatible request/response schema — core pipeline stub
- [ ] Auth at ingress: API key validation, per-key policy profile config
- [ ] Rate limiting per API key
- [ ] NeMo Guardrails integration: input content filter, PII detection, prompt injection detection
- [ ] Post-model output rails: toxicity filter, jailbreak detection (NeMo output rails or Llama Guard)
- [ ] Constitutional AI two-pass self-critique with configurable judge model
- [ ] User-editable constitution (YAML file, validated on startup)
- [ ] Configurable per-rail thresholds and enable/disable flags (YAML config)
- [ ] Refusal calibration: hard block / soft steer / informative refusal modes
- [ ] Full structured trace logging (JSON, append-only, request_id indexed)

### Add After Validation (v1.1 eval and feedback)

Add once the core pipeline is proven correct. These features require stable logs as their data source.

- [ ] Custom replay eval harness against POST /chat — trigger: first time you want to measure whether a config change improved or regressed safety
- [ ] lm-eval-harness integration — trigger: concern that guardrail tuning is hurting model capability
- [ ] CI/CD eval integration — trigger: any config change going to a shared deployment
- [ ] User-tunable guardrail rules with judge-guided suggestions — trigger: operators want AI help with threshold tuning, not just manual adjustment

### Future Consideration (v1.1 advanced)

Defer until core and eval stack are stable. These are high-complexity, high-value features that require the simpler features as a foundation.

- [ ] Streaming guardrails with per-N-token evaluation — defer: streaming support in NeMo on aarch64 needs validation; adds architectural complexity; streaming clients are a secondary use case for a local DGX workbench
- [ ] Distributed live red teaming — defer: requires stable trace logs, eval harness, and judge model; research-frontier complexity; ship after eval harness is proven
- [ ] Human-in-the-loop review dashboard — defer: optional per PROJECT.md; high implementation cost (UI); valuable only after trace volume justifies it
- [ ] Feedback loop into threshold calibration and fine-tuning data export — defer: requires human-in-the-loop corrections as input; builds on HITL dashboard

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| POST /chat endpoint + pipeline | HIGH | LOW | P1 |
| Auth + rate limiting | HIGH | LOW | P1 |
| Input content filter (NeMo) | HIGH | MEDIUM | P1 |
| PII detection + redaction | HIGH | MEDIUM | P1 |
| Prompt injection detection | HIGH | MEDIUM | P1 |
| Output toxicity filter | HIGH | MEDIUM | P1 |
| Jailbreak detection (post-model) | HIGH | HIGH | P1 |
| Constitutional AI self-critique | HIGH | HIGH | P1 |
| User-editable constitution | HIGH | MEDIUM | P1 |
| Configurable per-rail thresholds | HIGH | LOW | P1 |
| Refusal calibration modes | HIGH | HIGH | P1 |
| Full trace logging | HIGH | MEDIUM | P1 |
| Custom replay eval harness | HIGH | HIGH | P2 |
| lm-eval-harness integration | MEDIUM | MEDIUM | P2 |
| CI/CD eval integration | HIGH | MEDIUM | P2 |
| Judge-guided guardrail suggestions | MEDIUM | HIGH | P2 |
| Streaming guardrails | MEDIUM | HIGH | P3 |
| Distributed live red teaming | MEDIUM | HIGH | P3 |
| Human-in-the-loop dashboard | MEDIUM | HIGH | P3 |
| Feedback loop + fine-tuning export | MEDIUM | HIGH | P3 |

**Priority key:**
- P1: Must have for launch (v1.1 core)
- P2: Should have — add after core is validated
- P3: Nice to have — future milestone

## Competitor Feature Analysis

| Feature | NeMo Guardrails (standalone) | LiteLLM (existing) | This harness |
|---------|------------------------------|---------------------|--------------|
| Input content filtering | Yes — Colang 2.0 input rails | No — routing only | NeMo integration |
| PII detection | Yes — built-in rail | No | NeMo + Presidio |
| Prompt injection detection | Yes | No | NeMo |
| Output toxicity filtering | Yes — output rails | No | NeMo output rails |
| Constitutional AI critique | No | No | Custom two-pass pipeline |
| User-editable constitution | No | No | YAML config + judge model |
| Guardrail threshold tuning UI | No | No | Config file + judge suggestions |
| Refusal calibration modes | No — binary block | No | Custom: hard/soft/informative |
| Streaming guardrails | Partial (recently added) | N/A | NeMo streaming + N-token batching |
| Full trace logging | Partial (callback hooks) | Yes (request logs) | Structured JSON, OpenTelemetry |
| Replay eval harness | No | No | Custom |
| lm-eval-harness integration | No | No | API adapter |
| CI/CD eval gate | No | No | Custom runner + gates |
| Distributed red teaming | No | No | Custom (PyRIT/judge-based) |
| HITL review dashboard | No | No | Optional web UI |
| Feedback loop calibration | No | No | Custom |
| aarch64 support | Partial (C++ compile required) | Yes | Verified at setup |

## Sources

- [NeMo Guardrails Developer Guide (NVIDIA, 2025–2026)](https://docs.nvidia.com/nemo/guardrails/latest/index.html) — HIGH confidence
- [NeMo Guardrails Streaming Blog (NVIDIA Technical Blog)](https://developer.nvidia.com/blog/stream-smarter-and-safer-learn-how-nvidia-nemo-guardrails-enhance-llm-output-streaming/) — MEDIUM confidence (streaming feature exists; aarch64 behavior not confirmed)
- [NeMo Guardrails GitHub](https://github.com/NVIDIA-NeMo/Guardrails) — HIGH confidence for feature list
- [NeMo Guardrails aarch64 installation notes](https://docs.nvidia.com/nemo/guardrails/latest/getting-started/installation-guide.html) — MEDIUM confidence (requires C++ toolchain; potential annoy compilation issues on ARM)
- [OWASP LLM Top 10 2025 — Prompt Injection #1](https://cycode.com/blog/the-2025-owasp-top-10-addressing-software-supply-chain-and-llm-risks-with-cycode/) — HIGH confidence
- [Constitutional AI: Harmlessness from AI Feedback (Anthropic, arXiv 2212.08073)](https://arxiv.org/abs/2212.08073) — HIGH confidence for the technique; inference-time application is an extension of the training methodology
- [C3AI: Crafting and Evaluating Constitutions (ACM Web Conf 2025)](https://dl.acm.org/doi/10.1145/3696410.3714705) — MEDIUM confidence for constitution design patterns
- [Refusal Steering: Fine-grained Control over LLM Refusal Behaviour (arXiv 2512.16602)](https://arxiv.org/html/2512.16602) — MEDIUM confidence for refusal calibration patterns
- [SafeConstellations: Steering LLM Safety to Reduce Over-Refusals (arXiv 2508.11290)](https://arxiv.org/html/2508.11290v1) — MEDIUM confidence
- [C-SafeGen: Certified Safe LLM Generation with Claim-Based Streaming Guardrails](https://openreview.net/pdf/dfd7ac77a247ef06493d1b66dd3565ffedb70b24.pdf) — MEDIUM confidence for streaming guardrail patterns
- [LLM Guardrails Best Practices (Datadog, 2025)](https://www.datadoghq.com/blog/llm-guardrails-best-practices/) — MEDIUM confidence for production patterns
- [Automatic LLM Red Teaming (arXiv 2508.04451)](https://arxiv.org/abs/2508.04451) — MEDIUM confidence for red teaming architecture
- [lm-evaluation-harness (EleutherAI)](https://github.com/EleutherAI/lm-evaluation-harness) — HIGH confidence for capability benchmarks
- [Human-in-the-Loop Review Workflows for LLM Applications (Comet, 2025)](https://www.comet.com/site/blog/human-in-the-loop/) — MEDIUM confidence for HITL patterns
- [End-to-End LLM Observability in FastAPI with OpenTelemetry (freeCodeCamp)](https://www.freecodecamp.org/news/build-end-to-end-llm-observability-in-fastapi-with-opentelemetry/) — MEDIUM confidence for trace logging patterns
- [Top LLM Gateways 2025 (Maxim AI)](https://www.getmaxim.ai/articles/top-5-llm-gateways-in-2025-the-definitive-guide-for-production-ai-applications/) — MEDIUM confidence for table stakes baseline

---
*Feature research for: AI safety harness / FastAPI gateway (DGX Toolbox v1.1)*
*Researched: 2026-03-22*
