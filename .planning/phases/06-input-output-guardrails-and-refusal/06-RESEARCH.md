# Phase 6: Input/Output Guardrails and Refusal - Research

**Researched:** 2026-03-22
**Domain:** NeMo Guardrails, Unicode normalization, prompt injection detection, refusal modes
**Confidence:** HIGH (core stack verified against official docs and existing Phase 5 code)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Rail configuration model:**
- Global defaults in `harness/config/rails/rails.yaml`, tenants override specific thresholds in `tenants.yaml`
- Each rail has its own `enabled: true/false` + `threshold` + `refusal_mode` in config — per-rail granularity
- Strict Pydantic validation at startup: invalid config = harness refuses to start with clear error message
- Single config directory: `harness/config/rails/` contains both `rails.yaml` and NeMo Colang `.co` files together

**Refusal modes (per-rail):**
- Hard block (REFU-01): Return principled refusal; model never called (input) or response replaced (output)
- Soft steer (REFU-02): Flagged prompt sent to model with system instruction to reformulate — LLM rewrite, not template; adds latency for second model call; uses same LiteLLM backend
- Informative (REFU-03): Refusal names violated policy, explains why, suggests adjacent allowed query
- Trace records: `refusal_mode` (hard_block/soft_steer/informative), triggering rail name, original prompt (redacted), rewritten prompt (if soft-steer)

**Pipeline wiring:**
- Guardrails inline in proxy route handler, not as middleware
- Full pipeline: auth → rate limit → Unicode normalize → INPUT RAILS → proxy to LiteLLM → OUTPUT RAILS → response → background trace
- Input rails block before LiteLLM — blocked requests never reach model
- Output rails run synchronously before delivery
- Multiple input rail failures: run all rails, report all violations (not fail-fast)
- `guardrail_decisions` trace field: JSON array of `{rail, result, score, threshold}` for every enabled rail
- Bypass tenants skip entire guardrail pipeline (auth and trace still apply)

**Prompt injection and evasion detection:**
- Unicode normalization (INRL-01): NFC/NFKC + strip zero-width chars + confusables.txt lookup; log evasion attempts even when neutralized
- Prompt injection (INRL-04): Two-layer — fast regex heuristics + NeMo built-in jailbreak detection rail (LLM-as-judge)
- Jailbreak-success output detection (OURL-02): NeMo output self-check rails
- Per-tenant injection sensitivity: strict/balanced/permissive (matches pii_strictness pattern)

### Claude's Discretion
- NeMo Guardrails Colang flow definitions (specific rail implementations)
- Unicode confusables.txt source and update strategy
- Exact regex patterns for heuristic prompt injection detection
- NeMo LLM-as-judge prompt engineering for injection detection
- Output toxicity detection approach (NeMo built-in vs external classifier)
- Soft-steer system prompt wording for LLM rewrite

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| INRL-01 | Input normalized (Unicode NFC/NFKC + zero-width strip) before any classifier | Python `unicodedata` stdlib + confusable_homoglyphs library; normalize() pipeline documented |
| INRL-02 | NeMo Guardrails content filter detects/blocks disallowed input topics | NeMo built-in `self check input` + `content safety check input` flows; config.yml `rails.input.flows` |
| INRL-03 | PII and secrets detected in input via Presidio, rejected/redacted per policy | NeMo built-in `mask sensitive data on input` flow + existing `harness/pii/redactor.py` Presidio layer |
| INRL-04 | Prompt injection and jailbreak attempts detected and blocked | Two-layer: regex heuristics + NeMo `jailbreak detection heuristics` flow |
| INRL-05 | User can enable/disable and tune thresholds for each input rail via config | Custom `rails.yaml` config; Pydantic RailConfig model; NeMo `score_threshold` per-rail |
| OURL-01 | Model output scanned for toxicity/bias before delivery | NeMo `self check output` + `content safety check output` flows |
| OURL-02 | Jailbreak-success patterns in output detected and blocked | NeMo `self check output` flow; custom Colang flow for success indicator detection |
| OURL-03 | PII leakage in output detected and redacted | NeMo `mask sensitive data on output` flow + existing Presidio redactor |
| OURL-04 | User can enable/disable and tune thresholds for each output rail via config | Same `rails.yaml` config; per-rail enabled/threshold fields |
| REFU-01 | Hard block mode: policy-violating requests return principled refusal | GuardrailEngine returns refusal dict; proxy returns 400 JSON without calling LiteLLM |
| REFU-02 | Soft steer mode: borderline requests rewritten to allowed formulation | Second LiteLLM call with system prompt instructing reformulation |
| REFU-03 | Informative refusal mode: explains why and offers adjacent help | Refusal response template that includes rail name, reason, adjacent suggestion |
| REFU-04 | Refusal thresholds tunable from eval data | `threshold` field in rails.yaml per-rail; Pydantic float with restart-to-apply semantics |
</phase_requirements>

---

## Summary

Phase 6 adds the active guardrail layer to the existing FastAPI harness built in Phase 5. The architecture has two distinct halves: (1) a custom `GuardrailEngine` module that wraps NeMo Guardrails `LLMRails` plus owns the Unicode normalization and regex injection heuristics, and (2) inline wiring in `harness/proxy/litellm.py` that calls the engine before and after the LiteLLM proxy call.

NeMo Guardrails 0.21.0 (the current release as of March 2026) provides the `self check input`, `self check output`, `jailbreak detection heuristics`, `mask sensitive data on input/output`, and `content safety check input/output` built-in flows. These cover INRL-02, INRL-03, INRL-04, OURL-01, OURL-02, OURL-03 out of the box. The custom rails.yaml config + Pydantic validation layer adds the per-rail `enabled`/`threshold`/`refusal_mode` semantics that NeMo's native config.yml cannot express alone.

The critical architectural constraint from Phase 5 is that `LLMRails` MUST be instantiated at module level before `uvicorn.run()` due to `nest_asyncio` interaction. Phase 5 already verified this works on aarch64 DGX Spark. The `generate_async()` API accepts a messages list and returns a dict with the assistant's response content; when a rail blocks, it returns the configured refusal message rather than calling the downstream LLM.

**Primary recommendation:** Implement a `GuardrailEngine` class in `harness/guards/engine.py` that (1) owns the NeMo LLMRails instance, (2) runs normalize+input rails, (3) provides check_input/check_output methods returning a typed `GuardrailDecision` dataclass. Wire this into `chat_completions()` in `litellm.py` replacing the `# Phase 6` placeholders.

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| nemoguardrails | 0.21.0 | LLM guardrail framework (input/output rails, jailbreak detection) | Phase 5 confirmed working on aarch64; official NVIDIA toolkit |
| presidio-analyzer | >=2.2 | PII entity detection | Already in pyproject.toml; two-layer with existing redactor.py |
| presidio-anonymizer | >=2.2 | PII masking/replacement | Already in pyproject.toml |
| unicodedata | stdlib | NFC/NFKC normalization | Python stdlib; zero external dependency |
| pydantic | >=2.0 | RailConfig validation at startup | Established pattern throughout harness |
| pyyaml | >=6.0 | rails.yaml loading | Already in pyproject.toml |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| confusable_homoglyphs | 3.2.0 | Unicode homoglyph/confusable detection | INRL-01 confusables.txt lookup; install with `pip install confusable_homoglyphs[cli]` |
| langchain-openai | >=0.1 | ChatOpenAI LLM wrapper for NeMo LLMRails | Required to point NeMo at LiteLLM backend |
| re (stdlib) | stdlib | Prompt injection regex heuristics | Fast first-pass injection detection before NeMo LLM-as-judge |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| confusable_homoglyphs | unicodedata.normalize(NFKC) only | NFKC alone handles compatibility forms but misses same-script homoglyphs; confusable_homoglyphs adds the Unicode Security confusables.txt lookup |
| NeMo built-in sensitive data rail | Only use existing redactor.py | NeMo's `mask sensitive data on input` uses the same Presidio backend but integrates with the Colang flow control; duplicating via custom action is viable but more code |
| langchain-openai ChatOpenAI | litellm Python SDK directly | NeMo's `llm` parameter expects a LangChain BaseLLM; ChatOpenAI pointing at LiteLLM proxy is the documented integration path |

**Installation:**
```bash
pip install "confusable_homoglyphs[cli]" langchain-openai
```

---

## Architecture Patterns

### Recommended Project Structure
```
harness/
├── guards/
│   ├── __init__.py
│   ├── nemo_compat.py        # existing — phase 5 compat checks
│   ├── engine.py             # NEW — GuardrailEngine class (main addition)
│   └── normalizer.py         # NEW — Unicode normalize + zero-width strip + confusables
├── config/
│   ├── loader.py             # existing — extend TenantConfig with rail_overrides
│   ├── tenants.yaml          # existing — add per-tenant rail threshold fields
│   └── rails/
│       ├── rails.yaml        # NEW — global per-rail config (enabled/threshold/refusal_mode)
│       ├── config.yml        # NEW — NeMo config.yml (models section, rails section)
│       └── input_output.co   # NEW — Colang flow definitions
├── proxy/
│   └── litellm.py            # existing — wire normalize + input/output rails inline
└── tests/
    ├── test_guardrails.py    # NEW — unit tests for GuardrailEngine
    └── test_normalizer.py    # NEW — unit tests for normalizer
```

### Pattern 1: GuardrailEngine — Module-Level LLMRails Init
**What:** `LLMRails` is constructed at module import time (not inside lifespan or async handler) to avoid nest_asyncio conflict with uvicorn's event loop.
**When to use:** Always — this is a hard constraint confirmed in Phase 5 research and in the existing `nemo_compat.py` docstring.
**Example:**
```python
# harness/guards/engine.py
# Source: https://github.com/NVIDIA/NeMo-Guardrails/issues/137 (nest_asyncio note)
from nemoguardrails import LLMRails, RailsConfig
from langchain_openai import ChatOpenAI
import os

_RAILS_CONFIG_DIR = os.path.join(os.path.dirname(__file__), "..", "config", "rails")

# MODULE LEVEL — must execute before uvicorn.run()
_config = RailsConfig.from_path(_RAILS_CONFIG_DIR)
_llm = ChatOpenAI(
    model_name="gpt-3.5-turbo",       # overridden by config.yml model section
    openai_api_base=os.environ.get("LITELLM_BASE_URL", "http://localhost:4000"),
    openai_api_key="not-used-by-litellm",
)
_rails = LLMRails(_config, llm=_llm)
```

### Pattern 2: NeMo config.yml — Wiring Built-in Rails
**What:** `harness/config/rails/config.yml` defines the NeMo model and which built-in flow names to activate. The per-rail `enabled`/`threshold`/`refusal_mode` semantics live in the separate `rails.yaml` (Pydantic-validated), not in NeMo's config.yml.
**When to use:** NeMo's built-in flows handle the LLM-as-judge classification. Custom rails.yaml handles enable/threshold decisions.
**Example:**
```yaml
# harness/config/rails/config.yml
# Source: https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/configuration-reference.html
models:
  - type: main
    engine: openai
    model: gpt-3.5-turbo

rails:
  config:
    sensitive_data_detection:
      input:
        entities:
          - EMAIL_ADDRESS
          - PHONE_NUMBER
          - US_SSN
          - CREDIT_CARD
        mask_token: "[REDACTED]"
        score_threshold: 0.2
      output:
        entities:
          - EMAIL_ADDRESS
          - PHONE_NUMBER
          - US_SSN
          - CREDIT_CARD
  input:
    flows:
      - self check input
      - jailbreak detection heuristics
      - mask sensitive data on input
  output:
    flows:
      - self check output
      - mask sensitive data on output
```

### Pattern 3: Colang 1.0 Flow Definitions
**What:** `.co` files define the flow logic for self-check rails. Colang 1.0 (default in 0.21.0) uses `define flow` syntax.
**When to use:** To customize what "blocked" means and to add custom detection flows.
**Example:**
```colang
# harness/config/rails/input_output.co
# Source: NeMo Guardrails docs — self check input/output patterns

define flow self check input
  $allowed = execute self_check_input
  if not $allowed
    bot refuse to respond
    stop

define flow self check output
  $allowed = execute self_check_output
  if not $allowed
    bot refuse to respond
    stop

define bot refuse to respond
  "I'm not able to respond to that request."
```

### Pattern 4: Per-Rail Custom Config (rails.yaml)
**What:** A separate Pydantic-validated YAML config that mirrors each NeMo flow with `enabled`, `threshold`, and `refusal_mode` fields. This is NOT native NeMo config — it is the project's own config layer.
**When to use:** This is what makes INRL-05/OURL-04/REFU-04 possible (user-tunable thresholds).
**Example:**
```yaml
# harness/config/rails/rails.yaml
rails:
  - name: self_check_input
    enabled: true
    threshold: 0.7
    refusal_mode: hard_block
  - name: jailbreak_detection
    enabled: true
    threshold: 0.6
    refusal_mode: hard_block
  - name: sensitive_data_input
    enabled: true
    threshold: 0.2
    refusal_mode: informative
  - name: self_check_output
    enabled: true
    threshold: 0.7
    refusal_mode: hard_block
  - name: sensitive_data_output
    enabled: true
    threshold: 0.2
    refusal_mode: informative
```

### Pattern 5: Unicode Normalization Pipeline
**What:** Sequential normalization steps run before any classifier. Evasion attempts (homoglyphs, zero-width chars) are logged even when neutralized.
**When to use:** Applied to all message content strings at the very start of `chat_completions()`, before GuardrailEngine.check_input().
**Example:**
```python
# harness/guards/normalizer.py
import unicodedata
import re
from confusable_homoglyphs import confusables

# Zero-width and invisible characters by Unicode category/range
_ZERO_WIDTH_PATTERN = re.compile(
    r"[\u200b\u200c\u200d\u200e\u200f\ufeff\u00ad\u2060\u2061\u2062\u2063\u2064]"
)

def normalize(text: str) -> tuple[str, list[str]]:
    """NFC/NFKC normalize, strip zero-width chars, flag confusables.

    Returns:
        (normalized_text, list_of_evasion_flags)
    """
    flags = []
    # Step 1: NFKC (compatibility decomposition + canonical composition)
    nfkc = unicodedata.normalize("NFKC", text)
    if nfkc != text:
        flags.append("unicode_normalization_changed")

    # Step 2: Strip zero-width/invisible chars
    stripped = _ZERO_WIDTH_PATTERN.sub("", nfkc)
    if stripped != nfkc:
        flags.append("zero_width_chars_stripped")

    # Step 3: Confusables check (homoglyphs)
    # confusable_homoglyphs uses Unicode Security confusables.txt
    for char in stripped:
        if confusables.is_dangerous(char, preferred_aliases=["latin"]):
            flags.append("homoglyph_detected")
            break

    return stripped, flags
```

### Pattern 6: Inline Pipeline Wiring in chat_completions()
**What:** GuardrailEngine.check_input() is called after rate limiting but before LiteLLM. check_output() is called after LiteLLM but before returning.
**When to use:** This is the mandated location per CONTEXT.md decisions.
**Example:**
```python
# harness/proxy/litellm.py (modified)
from harness.guards.engine import guardrail_engine  # module-level singleton
from harness.guards.normalizer import normalize

@router.post("/v1/chat/completions")
async def chat_completions(request: Request, tenant: TenantConfig = Depends(verify_api_key)):
    # ... rate limiting ...

    body = await request.json()

    # Skip guardrails for bypass tenants
    if not tenant.bypass:
        # Normalize input
        messages = body.get("messages", [])
        normalized_messages, evasion_flags = normalize_messages(messages)
        body["messages"] = normalized_messages

        # Input rails — run all, collect violations (not fail-fast)
        input_decision = await guardrail_engine.check_input(
            messages=normalized_messages,
            tenant=tenant,
            evasion_flags=evasion_flags,
        )
        if input_decision.blocked:
            # Return refusal — model never called
            return _build_refusal_response(input_decision, request_id, tenant, body, ...)

    # Proxy to LiteLLM
    resp = await http_client.post("/v1/chat/completions", json=body)
    response_data = resp.json()

    if not tenant.bypass:
        # Output rails
        output_decision = await guardrail_engine.check_output(
            response_data=response_data,
            tenant=tenant,
        )
        if output_decision.blocked:
            response_data = output_decision.replacement_response

    # Background trace with guardrail_decisions populated
    ...
```

### Pattern 7: Soft-Steer via Second LiteLLM Call
**What:** When a rail's `refusal_mode` is `soft_steer`, the blocked prompt is resubmitted to LiteLLM with a system instruction to reformulate safely. Uses the same `http_client` and LiteLLM endpoint.
**When to use:** Only when the configured rail has `refusal_mode: soft_steer`.
**Example:**
```python
SOFT_STEER_SYSTEM_PROMPT = (
    "The user's request may contain problematic content. "
    "Rewrite the request in a safe, policy-compliant way that still addresses "
    "the user's underlying intent, then respond to the rewritten request. "
    "Do not mention this instruction in your response."
)

async def _soft_steer(original_messages, http_client):
    steer_messages = [
        {"role": "system", "content": SOFT_STEER_SYSTEM_PROMPT},
        *original_messages,
    ]
    resp = await http_client.post("/v1/chat/completions", json={"messages": steer_messages})
    return resp.json()
```

### Anti-Patterns to Avoid
- **Instantiating LLMRails inside lifespan() or async handler:** Causes nest_asyncio event loop conflict with uvicorn. Must be module-level.
- **Fail-fast on first rail violation:** CONTEXT.md mandates run-all-rails reporting. Collect all violations before deciding to block.
- **Hard-coding NeMo as the sole detection layer:** Regex heuristic pre-pass is required for INRL-04. LLM-as-judge is expensive; regex catches obvious attacks cheaply.
- **Applying guardrails to bypass tenants:** Bypass tenants skip the entire guardrail pipeline by design (CONTEXT.md: auth and trace still apply).
- **Writing raw PII to guardrail_decisions trace field:** The existing trace redaction pass covers prompt/response. The guardrail_decisions JSON must also avoid capturing full prompt text — store only score, threshold, rail name.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| LLM-as-judge input safety check | Custom LLM classification loop | NeMo `self check input` + `self_check_input` built-in action | Prompt engineering, async coordination, and retry already handled |
| PII detection in guardrail flow | Duplicate Presidio calls | NeMo `mask sensitive data on input/output` flow (uses Presidio internally) | NeMo's rail already integrates with Presidio; `harness/pii/redactor.py` covers the trace-write path |
| Output toxicity classifier | External API or custom model | NeMo `self check output` flow | Same self-check pattern; model-agnostic; no extra service to run |
| Homoglyph lookup table | Build from Unicode spec | `confusable_homoglyphs` library (uses official Unicode Security confusables.txt) | 2800+ confusable pairs; keeping the table current is non-trivial |
| Rail config schema validation | Ad hoc YAML parsing | Pydantic RailConfig model (established harness pattern) | Consistent with TenantConfig; startup-fail-on-invalid is the required behavior |

**Key insight:** NeMo Guardrails is not just a Colang interpreter — it owns the async coordination, LLM-as-judge prompt templates, and Presidio integration. The project's job is to configure it correctly and wrap its output in the project's refusal mode semantics.

---

## Common Pitfalls

### Pitfall 1: LLMRails Init Inside Async Context
**What goes wrong:** If `LLMRails(config)` is called inside `lifespan()` or `chat_completions()`, nest_asyncio fails to patch the already-running uvicorn event loop, causing a RuntimeError or hanging.
**Why it happens:** NeMo applies `nest_asyncio.apply()` on first import; this conflicts with uvicorn's event loop if done inside a coroutine.
**How to avoid:** Import and instantiate `LLMRails` at module level in `engine.py`. Importing `harness.guards.engine` in `main.py` lifespan (as a side-effect import) is fine to ensure init order.
**Warning signs:** `RuntimeError: This event loop is already running` or first request hangs indefinitely.

### Pitfall 2: NeMo generate_async Returns Refusal Text, Not an Exception
**What goes wrong:** Code expects an exception when a rail blocks; instead `generate_async()` returns a dict with the configured refusal message as the assistant content.
**Why it happens:** NeMo's design: "bot refuse to respond" is a Colang flow that returns the refusal string, not a raised exception.
**How to avoid:** Inspect the returned assistant content against known refusal phrases, OR use a custom Colang flow that sets a context variable `$blocked = true` detectable by the wrapper.
**Warning signs:** Blocked requests silently pass through as "I'm sorry, I can't respond to that" reaching the client.

### Pitfall 3: config.yml model section must match LiteLLM proxy capabilities
**What goes wrong:** NeMo's `self check input` uses the `main` model defined in `config.yml` for LLM-as-judge calls. If the model name doesn't exist in LiteLLM, the rail call fails.
**Why it happens:** NeMo falls back to `config.yml` model if no `llm` parameter is passed, or uses the passed `llm` object's model name for routing.
**How to avoid:** Pass `llm=ChatOpenAI(openai_api_base=LITELLM_BASE_URL, model_name=...)` to `LLMRails()` using a model that LiteLLM has configured. Keep config.yml model section consistent.
**Warning signs:** `openai.NotFoundError` or `litellm.exceptions.NotFoundError` on first guardrailed request.

### Pitfall 4: Colang 1.0 vs Colang 2.0 Flow Syntax
**What goes wrong:** Mixing Colang 1.0 `define flow` syntax with Colang 2.0 `flow` keyword causes parse errors.
**Why it happens:** NeMo 0.21.0 defaults to Colang 1.0 but supports 2.0 via `colang_version: 2.x` in config.yml. The two syntaxes are incompatible.
**How to avoid:** Use Colang 1.0 `define flow` syntax throughout (no `colang_version` key in config.yml). Only upgrade to 2.0 if a phase explicitly requires it.
**Warning signs:** `ColangParseError` or `SyntaxError` loading `.co` files.

### Pitfall 5: Run-All-Rails Requires Manual Aggregation
**What goes wrong:** NeMo's `generate_async()` stops at the first blocking rail. The project requirement is to collect all violations.
**Why it happens:** NeMo's pipeline is designed to stop on first block for efficiency.
**How to avoid:** Call `check_input_rail(rail_name, messages)` per-rail using NeMo's lower-level action execution, OR call `generate_async()` serially with each rail's config.yml subset and aggregate. The cleanest approach: implement each rail check as a separate NeMo action call via `execute_action()` and aggregate the `GuardrailDecision` list.
**Warning signs:** Only one rail ever appears in `guardrail_decisions` for requests that violate multiple rails.

### Pitfall 6: Zero-Width Character Pattern Scope
**What goes wrong:** Using `\s` or general whitespace strips in regex misses the full range of zero-width chars; some pass through and reach classifiers.
**Why it happens:** Python `\s` matches `\t\n\r\f\v\x20` — it does not match Unicode zero-width joiners, BOM, or soft hyphen.
**How to avoid:** Explicit character list pattern: `[\u200b-\u200f\ufeff\u00ad\u2060-\u2064]` covering zero-width space, zero-width non-joiner, zero-width joiner, LRM, RLM, BOM, soft hyphen, and invisible math operators.
**Warning signs:** Evasion test strings with `\u200b` inserted reach classifiers unstripped.

---

## Code Examples

Verified patterns from official sources:

### NeMo LLMRails with LiteLLM Backend
```python
# Source: https://github.com/BerriAI/litellm/blob/main/cookbook/Using_Nemo_Guardrails_with_LiteLLM_Server.ipynb
from langchain_openai import ChatOpenAI
from nemoguardrails import LLMRails, RailsConfig

config = RailsConfig.from_path("./harness/config/rails")
llm = ChatOpenAI(
    model_name="llama3.1",             # must exist in LiteLLM router
    openai_api_base="http://localhost:4000",
    openai_api_key="not-needed",
)
rails = LLMRails(config, llm=llm)
```

### Calling generate_async with messages
```python
# Source: https://docs.nvidia.com/nemo/guardrails/0.20.0/run-rails/using-python-apis/core-classes.html
response = await rails.generate_async(messages=[
    {"role": "user", "content": "Hello!"}
])
# response is a dict: {"role": "assistant", "content": "..."}
```

### Sensitive Data Rail config.yml
```yaml
# Source: https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/configuration-reference.html
rails:
  config:
    sensitive_data_detection:
      input:
        entities: [EMAIL_ADDRESS, PHONE_NUMBER, US_SSN, CREDIT_CARD]
        mask_token: "[REDACTED]"
        score_threshold: 0.2
      output:
        entities: [EMAIL_ADDRESS, PHONE_NUMBER, US_SSN, CREDIT_CARD]
  input:
    flows:
      - mask sensitive data on input
  output:
    flows:
      - mask sensitive data on output
```

### Unicode Normalization (stdlib)
```python
# Source: https://docs.python.org/3/library/unicodedata.html
import unicodedata
import re

def normalize_text(text: str) -> str:
    # NFKC: compatibility decomposition then canonical composition
    # Collapses full-width chars, superscripts, ligatures to base forms
    return unicodedata.normalize("NFKC", text)

# Zero-width characters explicit list
ZW_PATTERN = re.compile(
    r"[\u200b\u200c\u200d\u200e\u200f\ufeff\u00ad\u2060\u2061\u2062\u2063\u2064]"
)
```

### Colang 1.0 Self-Check Input Flow
```colang
# Source: NeMo Guardrails docs (self check input pattern)
define flow self check input
  $allowed = execute self_check_input
  if not $allowed
    bot refuse to respond
    stop

define bot refuse to respond
  "I'm not able to respond to that request."
```

### Pydantic RailConfig Model Pattern
```python
# Following established harness Pydantic pattern from loader.py
from pydantic import BaseModel, field_validator
from typing import Literal, List
import yaml

class RailConfig(BaseModel):
    name: str
    enabled: bool = True
    threshold: float = 0.7
    refusal_mode: Literal["hard_block", "soft_steer", "informative"] = "hard_block"

class RailsFile(BaseModel):
    rails: List[RailConfig]

def load_rails_config(config_path: str) -> List[RailConfig]:
    with open(config_path) as f:
        raw = yaml.safe_load(f)
    return RailsFile.model_validate(raw).rails
```

### GuardrailDecision Dataclass
```python
from dataclasses import dataclass, field
from typing import Optional

@dataclass
class RailResult:
    rail: str
    result: str       # "pass" | "block"
    score: float
    threshold: float

@dataclass
class GuardrailDecision:
    blocked: bool
    refusal_mode: Optional[str]         # "hard_block" | "soft_steer" | "informative"
    triggering_rail: Optional[str]
    all_results: list[RailResult] = field(default_factory=list)
    replacement_response: Optional[dict] = None
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Single global guardrail on/off | Per-rail enabled/threshold in config | NeMo 0.7+ | Fine-grained control without rebuilding |
| Colang 1.0 as only option | Colang 2.0 available (opt-in) | NeMo 0.10+ | More expressive but requires explicit version flag |
| OpenAI-only backend | Any LangChain LLM via `llm=` param | NeMo 0.5+ | LiteLLM proxy integration works transparently |
| Presidio as separate service | Presidio embedded via `mask sensitive data` rail | NeMo 0.8+ | No separate service needed; same process |

**Deprecated/outdated:**
- Colang 1.0 `define` keyword: Still the default in 0.21.0, but Colang 2.0 will become default in a future version. Use `define flow` for Phase 6; plan migration note for Phase 7+.
- `rails.generate()` (sync): Prefer `generate_async()` in FastAPI async context.

---

## Open Questions

1. **Run-all-rails aggregation with NeMo**
   - What we know: `generate_async()` stops at first blocking rail by design
   - What's unclear: Whether NeMo exposes a lower-level `execute_action()` API suitable for per-rail invocation without triggering the full generation pipeline
   - Recommendation: Implement each rail as a separate `generate_async()` call with a single-rail config, aggregate results. Accept the latency cost (parallel flag in NeMo config); or use NeMo's `generate_events()` which returns all events including rail decisions for post-hoc analysis

2. **Output toxicity detection approach**
   - What we know: NeMo `self check output` uses LLM-as-judge; NeMo `content safety check output` may require NeMo NIMs (cloud service)
   - What's unclear: Whether `content safety check output` is available offline/on-prem without NeMo NIM
   - Recommendation: Use `self check output` (LLM-as-judge, fully local) for OURL-01; avoid NeMo NIM dependency unless confirmed available

3. **Soft-steer second LiteLLM call latency**
   - What we know: Adds one full model round-trip; CONTEXT.md acknowledges the latency
   - What's unclear: Whether soft-steer should have a timeout/fallback to hard_block if the second call exceeds a threshold
   - Recommendation: Add configurable `soft_steer_timeout_ms` field to RailConfig with default 5000ms; fallback to hard_block on timeout

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | pytest 8.0+ with pytest-asyncio 0.25+ |
| Config file | `harness/pyproject.toml` (`[tool.pytest.ini_options]`, asyncio_mode=auto) |
| Quick run command | `cd /home/robert_li/dgx-toolbox/harness && python -m pytest tests/test_normalizer.py tests/test_guardrails.py -x -q` |
| Full suite command | `cd /home/robert_li/dgx-toolbox/harness && python -m pytest tests/ -q` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| INRL-01 | NFKC normalization changes homoglyphs/full-width | unit | `pytest tests/test_normalizer.py::test_nfkc_normalization -x` | ❌ Wave 0 |
| INRL-01 | Zero-width chars stripped | unit | `pytest tests/test_normalizer.py::test_zero_width_stripped -x` | ❌ Wave 0 |
| INRL-01 | Confusable homoglyphs flagged in evasion_flags | unit | `pytest tests/test_normalizer.py::test_homoglyph_flagged -x` | ❌ Wave 0 |
| INRL-02 | Content filter blocks disallowed topic | unit (mock NeMo) | `pytest tests/test_guardrails.py::test_content_filter_blocks -x` | ❌ Wave 0 |
| INRL-03 | PII in input triggers informative refusal | unit (mock NeMo) | `pytest tests/test_guardrails.py::test_pii_input_blocked -x` | ❌ Wave 0 |
| INRL-04 | Regex heuristic detects "ignore previous instructions" | unit | `pytest tests/test_guardrails.py::test_injection_regex_detected -x` | ❌ Wave 0 |
| INRL-05 | Disabled rail in rails.yaml is skipped | unit | `pytest tests/test_guardrails.py::test_disabled_rail_skipped -x` | ❌ Wave 0 |
| OURL-01 | Toxic output intercepted, not delivered to client | unit (mock NeMo) | `pytest tests/test_guardrails.py::test_toxic_output_blocked -x` | ❌ Wave 0 |
| OURL-02 | Jailbreak-success pattern in output blocked | unit (mock NeMo) | `pytest tests/test_guardrails.py::test_jailbreak_output_blocked -x` | ❌ Wave 0 |
| OURL-03 | PII in output redacted before delivery | unit (mock NeMo) | `pytest tests/test_guardrails.py::test_pii_output_redacted -x` | ❌ Wave 0 |
| OURL-04 | Output rail threshold change takes effect after restart | unit | `pytest tests/test_guardrails.py::test_threshold_config_loaded -x` | ❌ Wave 0 |
| REFU-01 | Hard block returns 400 with principled refusal JSON | integration | `pytest tests/test_proxy.py::test_hard_block_returns_400 -x` | ❌ Wave 0 |
| REFU-02 | Soft steer mode calls LiteLLM twice (second with system prompt) | integration | `pytest tests/test_proxy.py::test_soft_steer_second_call -x` | ❌ Wave 0 |
| REFU-03 | Informative refusal includes rail name and suggestion | unit | `pytest tests/test_guardrails.py::test_informative_refusal_content -x` | ❌ Wave 0 |
| REFU-04 | threshold=1.0 in rails.yaml causes all requests to pass | unit | `pytest tests/test_guardrails.py::test_threshold_permissive -x` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `cd /home/robert_li/dgx-toolbox/harness && python -m pytest tests/test_normalizer.py tests/test_guardrails.py -x -q`
- **Per wave merge:** `cd /home/robert_li/dgx-toolbox/harness && python -m pytest tests/ -q`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `harness/tests/test_normalizer.py` — covers INRL-01 (NFC/NFKC, zero-width, confusables)
- [ ] `harness/tests/test_guardrails.py` — covers INRL-02 through OURL-04 and REFU-03, REFU-04
- [ ] `harness/config/rails/rails.yaml` — per-rail config file (required before GuardrailEngine can load)
- [ ] `harness/config/rails/config.yml` — NeMo config (required for LLMRails.from_path())
- [ ] `harness/config/rails/input_output.co` — Colang flow definitions
- [ ] `harness/guards/engine.py` — GuardrailEngine class
- [ ] `harness/guards/normalizer.py` — Unicode normalization module
- [ ] Install: `pip install "confusable_homoglyphs[cli]" langchain-openai` — add to pyproject.toml dependencies

---

## Sources

### Primary (HIGH confidence)
- NeMo Guardrails PyPI (nemoguardrails 0.21.0, released 2026-03-12) — current version confirmed
- https://docs.nvidia.com/nemo/guardrails/0.20.0/run-rails/using-python-apis/core-classes.html — LLMRails, generate_async, RailsConfig.from_path
- https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/configuration-reference.html — sensitive_data_detection schema, score_threshold, mask_token, flows
- https://github.com/BerriAI/litellm/blob/main/cookbook/Using_Nemo_Guardrails_with_LiteLLM_Server.ipynb — LiteLLM + NeMo integration pattern
- `harness/guards/nemo_compat.py` — nest_asyncio module-level init constraint (Phase 5 verified)
- `harness/pii/redactor.py` — existing Presidio two-layer redactor (reusable for output PII rail)
- `harness/config/loader.py` — Pydantic TenantConfig pattern to follow for RailConfig
- https://docs.python.org/3/library/unicodedata.html — unicodedata.normalize stdlib API

### Secondary (MEDIUM confidence)
- https://pypi.org/project/confusable-homoglyphs/ — confusable_homoglyphs 3.2.0; maintenance status is "inactive past 12 months" but data is static Unicode spec; safe to use
- Deepwiki NeMo config reference — rails.input.flows, rails.output.flows, parallel flag (cross-referenced with official docs)
- NeMo Guardrails GitHub discussions #294, #600 — Presidio integration via `mask sensitive data` flow confirmed working

### Tertiary (LOW confidence)
- Colang 1.0 self-check flow syntax from web search — pattern consistent with multiple sources but not directly verified against 0.21.0 source; validate against actual `.co` file parsing on first run
- Regex injection heuristic patterns — from community sources (pytector, rebuff); treat as starting point, not authoritative

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — NeMo 0.21.0 on aarch64 confirmed working in Phase 5; all other deps in pyproject.toml
- Architecture: HIGH — module-level LLMRails init, inline pipeline wiring, Pydantic config patterns all from existing code and official docs
- Pitfalls: HIGH for nest_asyncio and Colang version (official sources); MEDIUM for run-all-rails aggregation (requires implementation experimentation)
- Refusal modes: HIGH — hard_block and informative are trivial; soft_steer latency/timeout is MEDIUM (no official guidance)

**Research date:** 2026-03-22
**Valid until:** 2026-04-22 (NeMo moves fast; re-verify if > 30 days)
