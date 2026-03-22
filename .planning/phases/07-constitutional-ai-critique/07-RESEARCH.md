# Phase 7: Constitutional AI Critique - Research

**Researched:** 2026-03-22
**Domain:** Constitutional AI critique loop, judge model integration, trace-driven tuning analysis
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Risk gating logic**
- High-risk determination uses existing output rail scores from Phase 6 (no separate risk classifier)
- Each output rail gets a `critique_threshold` in rails.yaml alongside its existing `threshold` — scores between `critique_threshold` and `threshold` (block) trigger the critique loop
- Single-pass critique: one critique + one revision. No iterative loops
- If revised output still scores high-risk after the single pass: fall back to hard block (reuse Phase 6 `_build_hard_block_refusal()` pattern). Log both original and failed revision in trace

**Constitution design**
- Constitution lives in `harness/config/constitution.yaml` — Pydantic-validated at startup (invalid file = harness refuses to start, matching Phase 6 rail config pattern)
- Principles are categorized with priority weights: grouped by category (safety, fairness, accuracy, helpfulness, etc.), each principle has a numeric priority weight
- Per-principle `enabled: true/false` toggle — users can disable specific principles without removing them. Matches per-rail toggle pattern from Phase 6
- Ships with sensible defaults: 10-15 default principles covering safety, fairness, accuracy, and helpfulness. User can modify, add, or remove

**Judge model config**
- Judge model calls go through LiteLLM (same `http_client` as user requests). Swapping judge model = changing a model name string in config
- Default judge model = same model as the request. Configurable to a different model in constitution.yaml
- Critique calls bypass guardrails — they're internal and need to discuss problematic content. Separate code path that skips guardrails but still writes trace
- Critique prompt includes only principles relevant to the triggering rail category (rail-to-principle category mapping), not all enabled principles
- Judge outputs structured JSON: `{violated_principles: [...], critique: "...", revision: "...", confidence: 0.0-1.0}`. Parseable, storable in `cai_critique` trace field, feedable into Phase 8 evals

**Tuning suggestions (CSTL-05)**
- Batch analysis endpoint — NOT per-request. User triggers on-demand. Keeps request latency unaffected
- Produces threshold + principle tuning suggestions: 1) rails with thresholds too high/low, 2) noisy principles (frequently trigger but rarely change outcomes), 3) missing principles for recurring issues. Ranked by impact
- Output: both human-readable ranked report with reasoning AND machine-readable YAML diffs the user can review and apply
- Exposed as Python API + CLI wrapper: core logic as `from harness.critique import analyze_traces`, exposed via POST /admin/suggest-tuning endpoint AND `python -m harness.critique analyze --since 24h`. Matches Phase 5 trace query pattern

### Claude's Discretion
- Critique prompt engineering (exact wording for judge model instructions)
- Default constitution principle text and categories
- Rail-to-principle category mapping specifics
- JSON schema for structured critique output
- Tuning suggestion ranking algorithm details
- Admin endpoint auth (whether /admin/* requires separate auth or reuses tenant auth)

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| CSTL-01 | Flagged outputs go through a two-pass critique→revise pipeline against constitutional principles | Architecture Pattern 1 (CritiqueEngine), integration point in litellm.py after output rails |
| CSTL-02 | Constitutional principles are user-editable via YAML config, validated on startup | ConstitutionConfig Pydantic model, constitution.yaml schema, lifespan init pattern |
| CSTL-03 | Judge model is configurable (default same-model, swappable to dedicated judge) | Judge model config in constitution.yaml, http_client reuse, trace field records judge model id |
| CSTL-04 | CAI critique is risk-gated — only triggered for outputs classified as high-risk by output rails | `critique_threshold` field added to RailConfig; gating logic compares score to critique_threshold |
| CSTL-05 | Judge model provides AI-guided suggestions for guardrail and constitution tuning based on trace history | `analyze_traces()` function, POST /admin/suggest-tuning, CLI `python -m harness.critique analyze` |
</phase_requirements>

---

## Summary

Phase 7 adds a Constitutional AI critique loop on top of the Phase 6 guardrail engine. The system is entirely self-contained within the existing codebase: the `cai_critique` column already exists in the SQLite schema (currently NULL), the `_build_hard_block_refusal()` method is already available for fallback, and the `http_client` on `app.state` can route judge model calls through LiteLLM with no new HTTP infrastructure.

The key design insight is the **double threshold**: each output rail in rails.yaml gets a `critique_threshold` field (must be less than the existing `threshold`). A score between `critique_threshold` and `threshold` triggers the critique loop; a score at or above `threshold` hard-blocks immediately without critique. This means only the "borderline high-risk" band is ever sent to the judge model, keeping the benign fast path completely untouched (CSTL-04 success criterion: exactly one model call for low-risk outputs).

The tuning analysis (CSTL-05) is fully decoupled from request latency — it reads historical trace data from SQLite, uses the judge model to reason about patterns, and emits both a human-readable ranked report and machine-readable YAML diffs. This mirrors the Phase 5 trace query pattern (`query_by_timerange`) and the Phase 4 CLI pattern (Python API + CLI wrapper).

**Primary recommendation:** Build `harness/critique/` as a new subpackage with three components: `engine.py` (critique loop), `constitution.py` (config loader), and `analyzer.py` (tuning analysis). Wire into `proxy/litellm.py` at the single insertion point between output rails and trace write.

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| pydantic | >=2.0 (already in deps via fastapi) | ConstitutionConfig validation at startup | Already used for RailConfig and TenantConfig — zero new dependencies |
| pyyaml | >=6.0 (already in deps) | Parse constitution.yaml | Already used for all config loading |
| aiosqlite | >=0.21 (already in deps) | Query trace history for tuning analysis | Already used in TraceStore |
| httpx | >=0.28 (already in deps) | Judge model calls via LiteLLM | `app.state.http_client` already configured with 120s timeout |
| json (stdlib) | stdlib | Serialize/deserialize cai_critique JSON | TraceStore already JSON-serializes guardrail_decisions |
| argparse / __main__ | stdlib | CLI for `python -m harness.critique analyze` | Matches existing harness pattern |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| fastapi (Router) | >=0.115 (already in deps) | POST /admin/suggest-tuning endpoint | Admin endpoint for on-demand tuning analysis |
| pytest + pytest-asyncio | >=8.0, >=0.25 (already in test deps) | Async unit tests for critique engine | All existing tests use this setup |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Direct LiteLLM http_client for judge calls | Separate httpx.AsyncClient for judge | http_client already configured with correct base_url, timeout, and connection pooling — no benefit to a separate client |
| JSON stdlib for structured critique output | Pydantic model for critique response | Pydantic would add value but the judge produces the JSON; we parse and store it, not validate at critique time |
| Inline analysis in /admin endpoint | Separate `analyzer.py` module | Module allows `from harness.critique import analyze_traces` Python API (CSTL-05 requirement) |

**Installation:** No new packages required. All dependencies are already in `pyproject.toml`.

---

## Architecture Patterns

### Recommended Project Structure

```
harness/
├── critique/
│   ├── __init__.py          # Exports: CritiqueEngine, ConstitutionConfig, analyze_traces
│   ├── engine.py            # CritiqueEngine: run_critique_loop(), _call_judge()
│   ├── constitution.py      # ConstitutionConfig Pydantic model, load_constitution()
│   └── analyzer.py          # analyze_traces(): reads SQLite, calls judge, emits report+YAML
├── config/
│   ├── constitution.yaml    # New: default principles (10-15), categories, priority weights
│   └── rails/
│       └── rails.yaml       # Modified: add critique_threshold to each output rail
└── proxy/
    └── litellm.py           # Modified: insert critique loop after output rails (step 7b)
```

### Pattern 1: CritiqueEngine — Single-Pass Loop

**What:** After output rails pass but score above `critique_threshold`, call judge model once, parse structured JSON response, re-run output rails on revision. If revision passes: return revision. If revision still high-risk: hard block.

**When to use:** Exactly when `any(r.score >= rail_config[r.rail].critique_threshold for r in output_decision.all_results if not output_decision.blocked)`.

**Integration point in litellm.py (after current step 7):**

```python
# 7b. Critique loop (risk-gated — runs only when output rails pass but score high-risk)
cai_critique_data = None
if not tenant.bypass and not output_decision.blocked:
    critique_engine = getattr(request.app.state, "critique_engine", None)
    if critique_engine is not None:
        critique_result = await critique_engine.run_critique_loop(
            response_data=response_data,
            output_results=output_decision.all_results,
            request_model=body.get("model", "unknown"),
            http_client=request.app.state.http_client,
        )
        if critique_result is not None:
            cai_critique_data = critique_result
            if critique_result.get("fallback_hard_block"):
                is_refusal = True
                response_data = guardrail_engine._build_hard_block_refusal("cai_critique")
            else:
                # Replace response with revised content
                response_data = _apply_revision(response_data, critique_result["revision"])
```

### Pattern 2: ConstitutionConfig — Pydantic Validation at Startup

**What:** Mirrors RailConfig/RailsFile pattern exactly. `load_constitution()` raises `ValueError` on malformed YAML — called in `lifespan()` before `yield`, so startup fails before accepting traffic.

```python
# Source: mirrors harness/config/rail_loader.py pattern
from pydantic import BaseModel
from typing import List, Literal

class Principle(BaseModel):
    id: str
    text: str
    category: str          # "safety" | "fairness" | "accuracy" | "helpfulness"
    priority: float        # 0.0-1.0 numeric weight
    enabled: bool = True

class ConstitutionConfig(BaseModel):
    judge_model: str = "default"   # "default" = use request model; any LiteLLM model string
    principles: List[Principle]

class ConstitutionFile(BaseModel):
    constitution: ConstitutionConfig

def load_constitution(config_path: str) -> ConstitutionConfig:
    # Raises ValueError on malformed YAML or schema violation — never silently falls back
    ...
```

**In main.py lifespan:**

```python
from harness.critique.constitution import load_constitution
from harness.critique.engine import CritiqueEngine

constitution_path = os.path.join(_CONFIG_DIR, "constitution.yaml")
constitution = load_constitution(constitution_path)
app.state.critique_engine = CritiqueEngine(
    constitution=constitution,
    guardrail_engine=app.state.guardrail_engine,
)
```

### Pattern 3: Judge Model Call — Bypass Guardrails

**What:** Critique calls must bypass the guardrail engine (internal calls discussing problematic content would self-block). Use `http_client` directly, NOT through the guardrail pipeline.

```python
# Source: derived from existing http_client usage in litellm.py
async def _call_judge(
    self,
    http_client,          # app.state.http_client — already has base_url + timeout
    model: str,           # from constitution.judge_model (or request model if "default")
    system_prompt: str,
    user_content: str,
) -> dict:
    """Call LiteLLM directly — bypasses GuardrailEngine entirely."""
    resp = await http_client.post(
        "/v1/chat/completions",
        json={
            "model": model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_content},
            ],
            "response_format": {"type": "json_object"},  # Request structured JSON output
        },
    )
    resp.raise_for_status()
    raw = resp.json()
    content = raw["choices"][0]["message"]["content"]
    return json.loads(content)
```

### Pattern 4: Structured cai_critique Trace Field

**What:** The `cai_critique` column is TEXT in SQLite, stores JSON. The shape must be consistent so Phase 8 evals can consume it.

```python
# Canonical cai_critique JSON shape stored in traces.cai_critique
{
    "triggered_by": "self_check_output",    # rail that exceeded critique_threshold
    "judge_model": "llama3.1",              # actual model identifier used (not "default")
    "original_score": 0.65,                # score that triggered critique
    "critique_threshold": 0.5,             # threshold that was crossed
    "judge_response": {
        "violated_principles": ["P-SAFETY-01"],
        "critique": "The response contains ...",
        "revision": "Here is a safer response ...",
        "confidence": 0.87
    },
    "revision_score": 0.3,                 # score after re-running output rails on revision
    "outcome": "revised" | "fallback_hard_block"
}
```

### Pattern 5: Tuning Analyzer — Batch On-Demand

**What:** `analyze_traces()` queries SQLite for traces with `cai_critique IS NOT NULL`, aggregates pattern data, calls judge model once with the aggregate, parses the response into ranked suggestions + YAML diff.

```python
# Source: mirrors TraceStore.query_by_timerange() usage
async def analyze_traces(
    trace_store,        # app.state.trace_store
    http_client,        # app.state.http_client
    constitution,       # app.state.critique_engine.constitution
    since: str,         # ISO8601 — "24h" resolved to timestamp before call
) -> dict:
    """
    Returns:
        {
            "report": "## Tuning Suggestions\n...",   # human-readable markdown
            "yaml_diffs": [                           # machine-readable YAML patches
                {"type": "threshold", "rail": "self_check_output", "current": 0.7, "suggested": 0.65},
                {"type": "principle", "action": "disable", "id": "P-ACCURACY-02", "reason": "..."},
            ],
            "generated_at": "2026-03-22T11:00:00Z",
        }
    """
```

**CLI entry point:**

```python
# harness/critique/__main__.py
# Usage: python -m harness.critique analyze --since 24h
import argparse, asyncio
from harness.critique.analyzer import analyze_traces
...
```

### Anti-Patterns to Avoid

- **Running critique on every request:** The critique_threshold gate is mandatory. Without it, every benign request hits the judge model (latency + cost). CSTL-04 success criterion explicitly tests that benign = 1 model call.
- **Iterative critique loop:** Single-pass only (locked decision). No while-loop retrying. If revision fails: hard block.
- **Importing CritiqueEngine in proxy/litellm.py at module level:** Use `getattr(request.app.state, "critique_engine", None)` guard, exactly as guardrail_engine is accessed. Ensures backward compatibility with tests that don't set app.state.critique_engine.
- **Calling guardrail engine on judge prompt:** Critique calls must bypass guardrails. A judge prompt that says "the user's output contained harmful content" will self-block.
- **Writing raw PII in critique output to trace:** The existing `_write_trace` PII redaction runs on `response_data` but not on `cai_critique_data`. Redact critique content (revision text) before storing in cai_critique JSON.
- **Blocking response delivery on tuning analysis:** POST /admin/suggest-tuning is fire-and-return (can be async); it must not be called in the request hot path.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Config validation for constitution.yaml | Custom YAML schema checker | Pydantic BaseModel (same as RailConfig) | ValidationError surfaces all schema violations with field paths — custom checker would miss nested errors |
| HTTP client for judge calls | New httpx.AsyncClient | `app.state.http_client` (existing) | Already has base_url, 120s timeout, connection pool, and correct LiteLLM routing |
| Structured JSON output from judge | Custom prompt + regex parser | `response_format: {"type": "json_object"}` (LiteLLM passthrough) | LiteLLM passes `response_format` to models that support it; reduces parse failures significantly |
| Score thresholding logic | New scoring class | Extend RailResult with `critique_threshold` | GuardrailDecision.all_results already has `.score` and `.threshold` per rail |
| Async CLI | Custom async runner | `asyncio.run()` in `__main__.py` | Two-line pattern; don't build a task runner |

---

## Common Pitfalls

### Pitfall 1: Judge Model Latency Unknown on aarch64

**What goes wrong:** The critique loop adds at minimum one extra LLM round-trip to high-risk requests. If the judge model is a 7B model on DGX Spark aarch64, P95 latency could be 5-30 seconds, making the synchronous critique loop unacceptable.

**Why it happens:** STATE.md explicitly flags this: "CAI judge model latency on DGX Spark aarch64 is unknown — async timeout values depend on actual hardware numbers."

**How to avoid:** Keep the synchronous approach for Phase 7 (simpler, matches existing pattern), but set an explicit asyncio timeout on `_call_judge()` (e.g., 60s). If timeout exceeded, log and return original response (fail-open for critique, not fail-closed). Do NOT implement async/background critique without first benchmarking — premature optimization here adds significant complexity.

**Warning signs:** Integration test for CSTL-01 success criterion exceeds 5s wall time in test suite — signals judge latency is a production concern.

### Pitfall 2: critique_threshold Must Be Validated Relative to threshold

**What goes wrong:** A constitution.yaml with `critique_threshold: 0.9` and `threshold: 0.7` means the critique zone is `[0.9, 0.7)` — an empty/inverted interval. The critique loop never triggers, but no error is raised.

**Why it happens:** Pydantic validates each field independently. Cross-field validation requires a `model_validator`.

**How to avoid:** Add a Pydantic `@model_validator(mode='after')` on `RailConfig` (after adding `critique_threshold`) that asserts `critique_threshold < threshold`. Raise `ValueError` at startup. Mirror the existing startup-fail pattern.

### Pitfall 3: Guardrail Engine Called on Critique Path

**What goes wrong:** A code path that calls `check_output()` on the revision before returning it would self-block any critique revision that mentions harmful content (which it always does).

**Why it happens:** Reflex to "validate all outputs" includes the revision. But the revision IS the critique output — it needs to discuss the original problematic content.

**How to avoid:** The `run_critique_loop()` method must call `http_client.post()` directly for the judge call, and re-run output rails on the REVISION TEXT only (not the critique/analysis text). The `judge_response.revision` field is what gets re-checked, not `judge_response.critique`.

### Pitfall 4: PII in cai_critique Trace Field

**What goes wrong:** The revision produced by the judge model may contain PII redacted from the original response. The existing `_write_trace()` function only redacts `response_data` — it does NOT redact `cai_critique_data`.

**Why it happens:** cai_critique was NULL in Phase 6; the redaction path was not built for it.

**How to avoid:** In `_write_trace()` (or just before constructing the trace record), apply `redact()` to `cai_critique_data["judge_response"]["revision"]` before serializing to JSON. The critique and violated_principles text can stay as-is.

### Pitfall 5: "default" Judge Model Needs to Be Resolved at Call Time

**What goes wrong:** If `constitution.judge_model == "default"`, the planner needs to store the actual model identifier in the trace (for CSTL-03 success criterion: "trace record shows the judge model identifier confirming the swap").

**Why it happens:** "default" is a config alias, not a real model name. The trace records a sentinel, not an inspectable identifier.

**How to avoid:** Resolve judge model at call time: `judge_model_id = body.get("model", "unknown") if constitution.judge_model == "default" else constitution.judge_model`. Store `judge_model_id` in cai_critique JSON, not the string "default".

### Pitfall 6: Tuning Analyzer Running on Empty Trace History

**What goes wrong:** `analyze_traces` called with `--since 24h` on a fresh install returns 0 traces with cai_critique. The judge model is called with empty data, producing hallucinated suggestions.

**Why it happens:** No guard on minimum sample size.

**How to avoid:** Add a minimum sample size check before calling the judge: if fewer than N traces with cai_critique exist in the time window, return a structured empty result with a clear message rather than calling the judge.

---

## Code Examples

### rails.yaml Extended with critique_threshold

```yaml
# harness/config/rails/rails.yaml — extended for Phase 7
rails:
  - name: self_check_input
    enabled: true
    threshold: 0.7
    refusal_mode: hard_block
    # No critique_threshold on INPUT rails — critique loop is output-only
  - name: self_check_output
    enabled: true
    threshold: 0.7
    critique_threshold: 0.5   # score in [0.5, 0.7) triggers critique loop
    refusal_mode: hard_block
  - name: jailbreak_output
    enabled: true
    threshold: 0.7
    critique_threshold: 0.5
    refusal_mode: hard_block
  - name: sensitive_data_output
    enabled: true
    threshold: 0.2
    critique_threshold: 0.15
    refusal_mode: informative
```

### constitution.yaml Default Schema

```yaml
# harness/config/constitution.yaml
constitution:
  judge_model: default    # "default" = use same model as request; or any LiteLLM model string

  principles:
    - id: P-SAFETY-01
      category: safety
      priority: 1.0
      enabled: true
      text: "Do not provide instructions, methods, or encouragement for harming people or property."

    - id: P-SAFETY-02
      category: safety
      priority: 0.95
      enabled: true
      text: "Do not generate or assist with content involving the exploitation of minors."

    - id: P-FAIRNESS-01
      category: fairness
      priority: 0.85
      enabled: true
      text: "Treat individuals and groups equitably; avoid reinforcing harmful stereotypes."

    - id: P-FAIRNESS-02
      category: fairness
      priority: 0.80
      enabled: true
      text: "Do not produce content that demeans, dehumanizes, or discriminates against protected groups."

    - id: P-ACCURACY-01
      category: accuracy
      priority: 0.75
      enabled: true
      text: "Do not present speculation or opinion as established fact."

    - id: P-ACCURACY-02
      category: accuracy
      priority: 0.70
      enabled: true
      text: "When uncertain, acknowledge uncertainty rather than fabricating information."

    - id: P-HELPFULNESS-01
      category: helpfulness
      priority: 0.60
      enabled: true
      text: "Where a request is declined, offer an adjacent safe alternative when possible."

    - id: P-HELPFULNESS-02
      category: helpfulness
      priority: 0.55
      enabled: true
      text: "Do not refuse benign requests out of excessive caution when no clear policy violation exists."
```

### Rail-to-Principle Category Mapping

```python
# harness/critique/engine.py
# Maps output rail names to principle categories that are relevant.
# Critique prompt includes ONLY matching-category principles.
RAIL_TO_CATEGORIES: dict[str, list[str]] = {
    "self_check_output":    ["safety", "accuracy"],
    "jailbreak_output":     ["safety"],
    "sensitive_data_output": ["safety", "fairness"],
}
```

### Critique Prompt Construction

```python
def _build_critique_prompt(
    self,
    output_text: str,
    triggering_rail: str,
    relevant_principles: list[Principle],
) -> tuple[str, str]:
    """Build (system_prompt, user_content) for the judge model call."""
    principle_list = "\n".join(
        f"- [{p.id}] {p.text}"
        for p in sorted(relevant_principles, key=lambda p: -p.priority)
        if p.enabled
    )
    system_prompt = (
        "You are a safety judge. Evaluate the following AI-generated text against "
        "the listed constitutional principles. Respond ONLY with valid JSON matching "
        "the schema: "
        '{"violated_principles": [<principle IDs>], "critique": "<explanation>", '
        '"revision": "<revised text>", "confidence": <0.0-1.0>}. '
        "The revision must address all identified violations while preserving the "
        "original intent as much as possible."
    )
    user_content = (
        f"Constitutional principles:\n{principle_list}\n\n"
        f"Triggering guardrail: {triggering_rail}\n\n"
        f"AI-generated text to evaluate:\n{output_text}"
    )
    return system_prompt, user_content
```

### RailConfig Extended with critique_threshold

```python
# harness/config/rail_loader.py — extended for Phase 7
from pydantic import BaseModel, model_validator
from typing import Optional, List, Literal

class RailConfig(BaseModel):
    name: str
    enabled: bool = True
    threshold: float = 0.7
    critique_threshold: Optional[float] = None  # None = no critique gate for this rail
    refusal_mode: Literal["hard_block", "soft_steer", "informative"] = "hard_block"

    @model_validator(mode='after')
    def validate_critique_threshold(self) -> 'RailConfig':
        if self.critique_threshold is not None:
            if self.critique_threshold >= self.threshold:
                raise ValueError(
                    f"Rail '{self.name}': critique_threshold ({self.critique_threshold}) "
                    f"must be less than threshold ({self.threshold})"
                )
        return self
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Hard block all borderline outputs | Critique-and-revise borderline outputs | CAI paper (Anthropic 2022), now standard in production safety systems | Better utility/safety tradeoff — harmful content is revised, not discarded |
| Monolithic safety classifier | Rail-per-concern with individual thresholds | Phase 6 established this pattern | Fine-grained control; critique_threshold extends this naturally |
| Manual threshold tuning | Trace-driven AI-guided tuning suggestions | Emerging pattern (Phase 7 CSTL-05) | Closes feedback loop between production behavior and config |

**Deprecated/outdated:**
- Iterative multi-pass critique loops: Initial CAI paper used multi-pass. Current production systems (including this design) use single-pass for latency reasons.
- Separate critique model infrastructure: Early implementations ran judge models as separate services. LiteLLM passthrough via existing http_client is the current standard for single-node deployments.

---

## Open Questions

1. **Judge model P95 latency on DGX Spark aarch64**
   - What we know: STATE.md flags this as unresolved. DGX Spark is aarch64; NeMo/Presidio were validated but judge LLM inference time was not benchmarked.
   - What's unclear: Whether synchronous critique (blocks response delivery) is acceptable in practice.
   - Recommendation: Implement synchronous with an explicit asyncio timeout (e.g., 60s). Add a test that measures judge call latency; if > 5s in integration tests, escalate to async background pattern in Phase 7 follow-up.

2. **Admin endpoint auth for POST /admin/suggest-tuning**
   - What we know: Marked Claude's discretion. Existing auth system is per-tenant API key bearer tokens.
   - What's unclear: Whether admin endpoints should require a separate "admin" tenant or just any authenticated tenant.
   - Recommendation: Reuse tenant auth (simplest — no new auth infrastructure). Document that any tenant with a valid API key can trigger tuning analysis. If access control is needed later, add `is_admin: bool` to TenantConfig in a follow-up phase.

3. **Minimum sample size for tuning analysis**
   - What we know: Not specified in decisions.
   - What's unclear: What sample size produces meaningful tuning suggestions.
   - Recommendation: Use N=10 as minimum (below this, return empty result with message). This is a reasonable floor; users can adjust via `--min-samples` CLI flag.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | pytest 8.x + pytest-asyncio 0.25.x |
| Config file | `harness/pyproject.toml` (`[tool.pytest.ini_options]`, `asyncio_mode = "auto"`) |
| Quick run command | `cd /home/robert_li/dgx-toolbox/harness && python -m pytest tests/test_critique.py -x -q` |
| Full suite command | `cd /home/robert_li/dgx-toolbox/harness && python -m pytest tests/ -q` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CSTL-01 | High-risk output triggers critique→revise; trace contains original + critique result | unit | `pytest tests/test_critique.py::test_critique_loop_triggered -x` | Wave 0 |
| CSTL-01 | Revised output returned to client when revision passes re-check | unit | `pytest tests/test_critique.py::test_critique_revision_returned -x` | Wave 0 |
| CSTL-01 | If revision still high-risk: hard block; trace contains fallback_hard_block | unit | `pytest tests/test_critique.py::test_critique_fallback_hard_block -x` | Wave 0 |
| CSTL-02 | Valid constitution.yaml loads without error | unit | `pytest tests/test_constitution.py::test_load_valid_constitution -x` | Wave 0 |
| CSTL-02 | Malformed constitution.yaml causes startup ValueError (not silent fallback) | unit | `pytest tests/test_constitution.py::test_malformed_constitution_raises -x` | Wave 0 |
| CSTL-02 | Disabled principle (enabled: false) not included in critique prompt | unit | `pytest tests/test_constitution.py::test_disabled_principle_excluded -x` | Wave 0 |
| CSTL-03 | Judge model in trace matches configured model (not "default" sentinel) | unit | `pytest tests/test_critique.py::test_judge_model_id_in_trace -x` | Wave 0 |
| CSTL-04 | Benign request (score below critique_threshold): exactly 1 model call | unit | `pytest tests/test_critique.py::test_benign_no_critique -x` | Wave 0 |
| CSTL-04 | critique_threshold >= threshold causes startup ValueError | unit | `pytest tests/test_rail_config.py::test_critique_threshold_invalid -x` | Wave 0 |
| CSTL-05 | analyze_traces() returns ranked report + yaml_diffs | unit | `pytest tests/test_analyzer.py::test_analyze_traces_returns_report -x` | Wave 0 |
| CSTL-05 | analyze_traces() on empty trace set returns empty result, not judge call | unit | `pytest tests/test_analyzer.py::test_analyze_empty_traces -x` | Wave 0 |

### Sampling Rate

- **Per task commit:** `cd /home/robert_li/dgx-toolbox/harness && python -m pytest tests/test_critique.py tests/test_constitution.py -x -q`
- **Per wave merge:** `cd /home/robert_li/dgx-toolbox/harness && python -m pytest tests/ -q`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps

- [ ] `harness/tests/test_critique.py` — covers CSTL-01, CSTL-03, CSTL-04
- [ ] `harness/tests/test_constitution.py` — covers CSTL-02
- [ ] `harness/tests/test_analyzer.py` — covers CSTL-05
- [ ] `harness/tests/test_rail_config.py` — add `test_critique_threshold_invalid` to existing file

---

## Sources

### Primary (HIGH confidence)

- Direct codebase inspection: `harness/guards/engine.py`, `harness/guards/types.py`, `harness/config/rail_loader.py`, `harness/proxy/litellm.py`, `harness/main.py`, `harness/traces/store.py`, `harness/traces/schema.sql`, `harness/config/rails/rails.yaml` — all Phase 5-6 patterns verified from source
- `harness/pyproject.toml` — dependency versions and pytest config confirmed
- `.planning/phases/07-constitutional-ai-critique/07-CONTEXT.md` — locked decisions read verbatim
- `.planning/STATE.md` — accumulated architectural decisions and known blockers

### Secondary (MEDIUM confidence)

- Constitutional AI patterns: Anthropic CAI paper (2022) — single-pass critique-and-revise is current production standard. This implementation matches the paper's core loop.
- LiteLLM `response_format: {"type": "json_object"}` passthrough: Standard LiteLLM feature; passes through to OpenAI-compatible endpoints that support JSON mode.

### Tertiary (LOW confidence)

- Tuning suggestion ranking algorithm: No prior art in this codebase. Design proposed (impact-ranked by frequency × outcome-change rate) is reasonable but untested. Flag for validation during implementation.

---

## Metadata

**Confidence breakdown:**

- Standard stack: HIGH — zero new dependencies; all libraries verified in pyproject.toml
- Architecture: HIGH — all patterns derived directly from existing Phase 5-6 source code
- Integration points: HIGH — exact line locations in litellm.py and main.py identified
- Pitfalls: HIGH — most derived from explicit flags in STATE.md or direct code inspection
- Tuning analysis ranking: LOW — no prior art; design is reasonable but needs validation during implementation

**Research date:** 2026-03-22
**Valid until:** 2026-06-22 (stable stack; constitution.yaml format is internal)
