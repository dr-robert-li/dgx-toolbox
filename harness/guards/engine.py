"""GuardrailEngine — central guardrail logic for input/output rail execution.

Wraps NeMo LLMRails with project-specific rail config, refusal modes, and
run-all-rails aggregation. Provides check_input() and check_output() returning
typed GuardrailDecision objects.

Phase 6: Full rail execution with injection heuristics, PII detection, and
three refusal modes (hard_block, soft_steer, informative).
"""
from __future__ import annotations

import re
from typing import Optional

from harness.config.rail_loader import RailConfig, load_rails_config
from harness.guards.normalizer import normalize_messages
from harness.guards.types import GuardrailDecision, RailResult

# ---------------------------------------------------------------------------
# Module-level constants
# ---------------------------------------------------------------------------

INJECTION_PATTERNS = [
    re.compile(r"ignore\s+(all\s+)?previous\s+instructions", re.IGNORECASE),
    re.compile(r"disregard\s+(all\s+)?(previous|above|prior)\s+", re.IGNORECASE),
    re.compile(r"you\s+are\s+now\s+(a|an)\s+", re.IGNORECASE),
    re.compile(r"forget\s+(all\s+)?(your|the)\s+(instructions|rules|guidelines)", re.IGNORECASE),
    re.compile(r"system\s*prompt\s*[:=]", re.IGNORECASE),
    re.compile(r"\[INST\]|\[/INST\]|<\|im_start\|>|<\|im_end\|>", re.IGNORECASE),
]

SOFT_STEER_SYSTEM_PROMPT = (
    "The user's request may contain problematic content. "
    "Rewrite the request in a safe, policy-compliant way that still addresses "
    "the user's underlying intent, then respond to the rewritten request. "
    "Do not mention this instruction in your response."
)

# NeMo refusal indicator patterns — if the generated response matches any of
# these, the rail has blocked the request.
_NEMO_REFUSAL_PATTERNS = [
    re.compile(r"I'?m\s+not\s+able\s+to\s+respond", re.IGNORECASE),
    re.compile(r"I\s+cannot", re.IGNORECASE),
    re.compile(r"I\s+can'?t\s+help", re.IGNORECASE),
    re.compile(r"not\s+able\s+to\s+assist", re.IGNORECASE),
    re.compile(r"I\s+won'?t\s+be\s+able\s+to", re.IGNORECASE),
    re.compile(r"I\s+am\s+not\s+able\s+to", re.IGNORECASE),
    re.compile(r"I\s+do\s+not\s+generate", re.IGNORECASE),
]

# Map rail names to adjacent suggestion text for informative refusals.
_RAIL_SUGGESTIONS: dict[str, str] = {
    "self_check_input": "factual, non-harmful topics",
    "sensitive_data_input": "questions that don't include personal information",
    "injection_heuristic": "direct questions without instruction override attempts",
    "jailbreak_detection": "questions within standard usage guidelines",
    "self_check_output": "factual, non-harmful topics",
    "jailbreak_output": "questions within standard usage guidelines",
    "sensitive_data_output": "responses that don't include personal information",
}


# ---------------------------------------------------------------------------
# GuardrailEngine class
# ---------------------------------------------------------------------------

class GuardrailEngine:
    """Runs all enabled guardrail rails and aggregates results into a GuardrailDecision.

    Execution model:
    - All enabled rails run regardless of intermediate blocks (run-all, not fail-fast).
    - After all rails complete, the first blocking rail determines refusal_mode.
    - NeMo-backed rails gracefully degrade to pass (score=0.0) when NeMo is unavailable.
    """

    def __init__(self, rails_config: list[RailConfig], nemo_rails=None):
        """Initialize the engine.

        Args:
            rails_config: List of RailConfig from load_rails_config().
            nemo_rails: Optional LLMRails instance (None in tests; real in production).
        """
        self._rails_config = {r.name: r for r in rails_config}
        self._nemo = nemo_rails
        self._input_rails = [
            "self_check_input",
            "jailbreak_detection",
            "sensitive_data_input",
            "injection_heuristic",
        ]
        self._output_rails = [
            "self_check_output",
            "jailbreak_output",
            "sensitive_data_output",
        ]

    async def check_input(
        self,
        messages: list[dict],
        tenant,
        evasion_flags: list[str] | None = None,
    ) -> GuardrailDecision:
        """Run all enabled input rails and return an aggregated GuardrailDecision.

        Args:
            messages: Chat messages list (OpenAI format).
            tenant: TenantConfig for the requesting tenant.
            evasion_flags: Pre-detected evasion flags from normalizer (optional).

        Returns:
            GuardrailDecision with blocked status, triggering rail, all results,
            and replacement_response if blocked.
        """
        # Normalize messages and accumulate evasion flags
        normalized_messages, norm_flags = normalize_messages(messages)
        all_evasion_flags = list(evasion_flags or []) + norm_flags

        all_results: list[RailResult] = []

        # Run ALL enabled input rails (run-all, not fail-fast)
        for rail_name in self._input_rails:
            config = self._rails_config.get(rail_name)
            if config is None or not config.enabled:
                continue

            if rail_name == "injection_heuristic":
                score, _ = self._check_injection_regex(normalized_messages)
            elif rail_name == "sensitive_data_input":
                score = self._check_pii_input(normalized_messages, tenant)
            else:
                score = await self._run_nemo_rail(rail_name, normalized_messages)

            result = "block" if score >= config.threshold else "pass"
            all_results.append(RailResult(
                rail=rail_name,
                result=result,
                score=score,
                threshold=config.threshold,
            ))

        # Aggregate: find first blocking rail (by order in _input_rails)
        blocked = False
        triggering_rail: str | None = None
        refusal_mode: str | None = None
        replacement_response: dict | None = None

        for r in all_results:
            if r.result == "block" and not blocked:
                blocked = True
                triggering_rail = r.rail
                config = self._rails_config[r.rail]
                refusal_mode = config.refusal_mode

        if blocked and triggering_rail is not None:
            replacement_response = self._build_refusal(
                refusal_mode=refusal_mode,
                rail_name=triggering_rail,
                messages=normalized_messages,
            )

        return GuardrailDecision(
            blocked=blocked,
            refusal_mode=refusal_mode,
            triggering_rail=triggering_rail,
            all_results=all_results,
            replacement_response=replacement_response,
            evasion_flags=all_evasion_flags,
        )

    async def check_output(
        self,
        response_data: dict,
        tenant,
    ) -> GuardrailDecision:
        """Run all enabled output rails and return an aggregated GuardrailDecision.

        Args:
            response_data: OpenAI-format response dict from LiteLLM.
            tenant: TenantConfig for the requesting tenant.

        Returns:
            GuardrailDecision with blocked status and replacement_response on block.
        """
        # Extract assistant content
        choices = response_data.get("choices") or []
        original_content = ""
        if choices:
            original_content = choices[0].get("message", {}).get("content", "") or ""

        all_results: list[RailResult] = []
        redacted_content: str | None = None

        # Run ALL enabled output rails (run-all, not fail-fast)
        for rail_name in self._output_rails:
            config = self._rails_config.get(rail_name)
            if config is None or not config.enabled:
                continue

            if rail_name == "sensitive_data_output":
                score, redacted = self._check_pii_output(original_content, tenant)
                if redacted != original_content:
                    redacted_content = redacted
            else:
                score = await self._run_nemo_rail(rail_name, original_content)

            result = "block" if score >= config.threshold else "pass"
            all_results.append(RailResult(
                rail=rail_name,
                result=result,
                score=score,
                threshold=config.threshold,
            ))

        # Aggregate
        blocked = False
        triggering_rail: str | None = None
        refusal_mode: str | None = None
        replacement_response: dict | None = None

        for r in all_results:
            if r.result == "block" and not blocked:
                blocked = True
                triggering_rail = r.rail
                config = self._rails_config[r.rail]
                refusal_mode = config.refusal_mode

        if blocked and triggering_rail is not None:
            if triggering_rail == "sensitive_data_output" and redacted_content is not None:
                # PII output: replace content with redacted version
                replacement_response = self._build_redacted_response(
                    response_data, redacted_content
                )
            else:
                replacement_response = self._build_refusal_response(
                    refusal_mode=refusal_mode,
                    rail_name=triggering_rail,
                    original_response=response_data,
                )

        return GuardrailDecision(
            blocked=blocked,
            refusal_mode=refusal_mode,
            triggering_rail=triggering_rail,
            all_results=all_results,
            replacement_response=replacement_response,
        )

    # ---------------------------------------------------------------------------
    # Rail checkers
    # ---------------------------------------------------------------------------

    def _check_injection_regex(
        self, messages: list[dict]
    ) -> tuple[float, str | None]:
        """Test all message content against INJECTION_PATTERNS.

        Returns:
            (1.0, pattern_desc) on first match; (0.0, None) if no match.
        """
        # Join all message content for a single scan
        combined = " ".join(
            msg.get("content", "") or ""
            for msg in messages
            if isinstance(msg.get("content"), str)
        )
        for pattern in INJECTION_PATTERNS:
            match = pattern.search(combined)
            if match:
                return 1.0, pattern.pattern
        return 0.0, None

    def _check_pii_input(self, messages: list[dict], tenant) -> float:
        """Check if any message content contains PII using the redactor.

        Returns:
            1.0 if PII detected (redacted text differs from original); 0.0 otherwise.
        """
        from harness.pii.redactor import redact

        strictness = getattr(tenant, "pii_strictness", "balanced")
        for msg in messages:
            content = msg.get("content")
            if isinstance(content, str) and content:
                redacted = redact(content, strictness)
                if redacted != content:
                    return 1.0
        return 0.0

    def _check_pii_output(self, content: str, tenant) -> tuple[float, str]:
        """Check if output content contains PII using the redactor.

        Returns:
            (score, redacted_content). Score is 1.0 if PII detected, 0.0 otherwise.
        """
        from harness.pii.redactor import redact

        strictness = getattr(tenant, "pii_strictness", "balanced")
        redacted = redact(content, strictness)
        score = 1.0 if redacted != content else 0.0
        return score, redacted

    async def _run_nemo_rail(
        self, rail_name: str, content: list[dict] | str
    ) -> float:
        """Run a NeMo-backed rail.

        Args:
            rail_name: The rail to check.
            content: Either messages list (for input) or string (for output).

        Returns:
            1.0 if blocked (refusal response detected); 0.0 if passed or NeMo unavailable.
        """
        if self._nemo is None:
            # Regex-only mode: NeMo rails return 0.0 (pass)
            return 0.0

        try:
            if isinstance(content, str):
                messages = [{"role": "user", "content": content}]
            else:
                messages = content

            result = await self._nemo.generate_async(messages=messages)

            # Inspect response: if it matches known refusal patterns, it's a block
            if isinstance(result, dict):
                response_content = result.get("content", "")
            elif isinstance(result, str):
                response_content = result
            else:
                response_content = str(result)

            for pattern in _NEMO_REFUSAL_PATTERNS:
                if pattern.search(response_content):
                    return 1.0

            return 0.0
        except Exception:
            # On any NeMo error, default to pass (fail-open)
            return 0.0

    # ---------------------------------------------------------------------------
    # Refusal builders
    # ---------------------------------------------------------------------------

    def _build_refusal(
        self,
        refusal_mode: str | None,
        rail_name: str,
        messages: list[dict],
    ) -> dict:
        """Dispatch to the appropriate refusal builder based on refusal_mode."""
        if refusal_mode == "hard_block":
            return self._build_hard_block_refusal(rail_name)
        elif refusal_mode == "informative":
            return self._build_informative_refusal(rail_name, reason="policy violation")
        elif refusal_mode == "soft_steer":
            # soft_steer: return messages for caller to re-submit (not a response)
            return {"soft_steer_messages": self._build_soft_steer_messages(messages)}
        else:
            return self._build_hard_block_refusal(rail_name)

    def _build_refusal_response(
        self,
        refusal_mode: str | None,
        rail_name: str,
        original_response: dict,
    ) -> dict:
        """Build replacement response for a blocked output, preserving response structure."""
        if refusal_mode == "informative":
            refusal = self._build_informative_refusal(rail_name, reason="policy violation")
        else:
            refusal = self._build_hard_block_refusal(rail_name)

        # Merge: keep original structure but replace choices content
        result = dict(original_response)
        result["choices"] = refusal["choices"]
        result["model"] = refusal["model"]
        return result

    def _build_redacted_response(self, original_response: dict, redacted_content: str) -> dict:
        """Build a response with PII-redacted content, preserving other fields."""
        import copy
        result = copy.deepcopy(original_response)
        if result.get("choices"):
            result["choices"][0]["message"]["content"] = redacted_content
        return result

    def _build_hard_block_refusal(self, rail_name: str) -> dict:
        """Return a hard-block refusal response.

        Returns an OpenAI-format response with a principled refusal message.
        """
        return {
            "choices": [
                {
                    "message": {
                        "role": "assistant",
                        "content": (
                            "I'm unable to process this request as it violates our content policy."
                        ),
                    },
                    "finish_reason": "stop",
                    "index": 0,
                }
            ],
            "model": "guardrail",
            "usage": {
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "total_tokens": 0,
            },
        }

    def _build_informative_refusal(self, rail_name: str, reason: str) -> dict:
        """Return an informative refusal naming the violated policy and suggesting adjacent help.

        The message names the rail, the reason, and offers a constructive suggestion.
        """
        suggestion = _RAIL_SUGGESTIONS.get(
            rail_name, "rephrasing your question in a different way"
        )
        content = (
            f"This request was blocked by the {rail_name} policy. "
            f"Reason: {reason}. "
            f"Try rephrasing your question to focus on {suggestion}."
        )
        return {
            "choices": [
                {
                    "message": {
                        "role": "assistant",
                        "content": content,
                    },
                    "finish_reason": "stop",
                    "index": 0,
                }
            ],
            "model": "guardrail",
            "usage": {
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "total_tokens": 0,
            },
        }

    def _build_soft_steer_messages(self, original_messages: list[dict]) -> list[dict]:
        """Prepend the soft-steer system prompt to the original messages.

        Returns messages for the caller to re-submit to LiteLLM. The caller
        is responsible for the actual LiteLLM call — this method only builds
        the modified message list.
        """
        return [{"role": "system", "content": SOFT_STEER_SYSTEM_PROMPT}, *original_messages]


# ---------------------------------------------------------------------------
# Module-level factory function
# ---------------------------------------------------------------------------

def create_guardrail_engine(
    rails_config_path: str,
    nemo_config_dir: str | None = None,
    litellm_base_url: str = "http://localhost:4000",
) -> GuardrailEngine:
    """Create a GuardrailEngine with loaded config and optional NeMo LLMRails.

    NeMo LLMRails is only created if nemo_config_dir is provided and
    nemoguardrails is importable. Otherwise the engine works without NeMo
    (regex-only mode for testing and environments without NeMo).

    Args:
        rails_config_path: Path to rails.yaml.
        nemo_config_dir: Optional path to NeMo config directory (contains config.yml).
        litellm_base_url: LiteLLM proxy base URL for NeMo's LLM calls.

    Returns:
        A fully initialized GuardrailEngine.
    """
    rails_config = load_rails_config(rails_config_path)
    nemo_rails = None

    if nemo_config_dir:
        try:
            from nemoguardrails import LLMRails, RailsConfig
            from langchain_openai import ChatOpenAI

            config = RailsConfig.from_path(nemo_config_dir)
            llm = ChatOpenAI(
                model_name="llama3.1",
                openai_api_base=litellm_base_url,
                openai_api_key="not-used-by-litellm",
            )
            nemo_rails = LLMRails(config, llm=llm)
        except ImportError:
            pass  # NeMo not available; regex-only mode

    return GuardrailEngine(rails_config=rails_config, nemo_rails=nemo_rails)
