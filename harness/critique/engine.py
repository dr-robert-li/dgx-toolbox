"""CritiqueEngine — Constitutional AI critique-revise loop.

Implements single-pass critique-revise for borderline outputs:
  - Risk-gated: only runs when output score >= critique_threshold but < threshold
  - Judge model: configurable or defaults to request model
  - Category-filtered principles: only principles relevant to the triggering rail
  - PII-redacted revision before trace storage
  - Fail-open: timeout or parse failure returns None
"""
from __future__ import annotations

import asyncio
import json
from typing import Optional

from harness.critique.constitution import ConstitutionConfig, Principle
from harness.guards.types import GuardrailDecision, RailResult
from harness.pii.redactor import redact

# ---------------------------------------------------------------------------
# Rail → principle category mapping
# ---------------------------------------------------------------------------

RAIL_TO_CATEGORIES: dict[str, list[str]] = {
    "self_check_output": ["safety", "accuracy"],
    "jailbreak_output": ["safety"],
    "sensitive_data_output": ["safety", "fairness"],
}


# ---------------------------------------------------------------------------
# CritiqueEngine
# ---------------------------------------------------------------------------

class CritiqueEngine:
    """Single-pass critique-revise loop gated by per-rail critique_threshold.

    High-risk outputs (score >= critique_threshold AND not blocked) are sent
    to a judge LLM with relevant constitutional principles. If the revision
    still scores high-risk on re-check, the response falls back to hard block.
    """

    def __init__(
        self,
        constitution: ConstitutionConfig,
        guardrail_engine,
    ) -> None:
        """Initialize with a constitution and a guardrail engine for re-checking.

        Args:
            constitution: Loaded ConstitutionConfig with principles and judge_model.
            guardrail_engine: GuardrailEngine instance used for revision re-check.
        """
        self._constitution = constitution
        self._guardrail_engine = guardrail_engine

    @property
    def constitution(self) -> ConstitutionConfig:
        """Public access to the constitution config."""
        return self._constitution

    async def run_critique_loop(
        self,
        response_data: dict,
        output_results: list[RailResult],
        request_model: str,
        http_client,
        pii_strictness: str = "balanced",
    ) -> dict | None:
        """Run critique-revise loop for borderline outputs.

        Args:
            response_data: OpenAI-format response dict from LiteLLM.
            output_results: RailResult list from GuardrailEngine.check_output().
            request_model: The model name from the original request.
            http_client: httpx.AsyncClient (base_url already set to LiteLLM).
            pii_strictness: PII redaction strictness level for revision text.

        Returns:
            cai_critique dict if critique ran, None if benign or on failure (fail-open).
        """
        # Find first rail that exceeds critique_threshold (and was not blocked)
        triggering_rail: str | None = None
        triggering_score: float = 0.0
        critique_threshold_value: float = 0.0

        for rail_result in output_results:
            rail_config = self._guardrail_engine._rails_config.get(rail_result.rail)
            if rail_config is None:
                continue
            if rail_config.critique_threshold is None:
                continue
            # Must score >= critique_threshold AND output was not blocked (< threshold)
            if (
                rail_result.score >= rail_config.critique_threshold
                and rail_result.result != "block"
            ):
                triggering_rail = rail_result.rail
                triggering_score = rail_result.score
                critique_threshold_value = rail_config.critique_threshold
                break

        if triggering_rail is None:
            return None  # No rail exceeded critique_threshold — benign

        # Resolve judge model
        if self._constitution.judge_model == "default":
            resolved_judge_model = request_model
        else:
            resolved_judge_model = self._constitution.judge_model

        # Filter principles: enabled AND in relevant categories for this rail
        relevant_categories = RAIL_TO_CATEGORIES.get(triggering_rail, ["safety"])
        relevant_principles = [
            p for p in self._constitution.principles
            if p.enabled and p.category in relevant_categories
        ]

        # Extract output text
        choices = response_data.get("choices") or []
        output_text = ""
        if choices:
            output_text = choices[0].get("message", {}).get("content", "") or ""

        # Build critique prompt
        system_prompt, user_content = self._build_critique_prompt(
            output_text=output_text,
            triggering_rail=triggering_rail,
            relevant_principles=relevant_principles,
        )

        # Call judge with timeout — fail-open on any error
        try:
            judge_response = await asyncio.wait_for(
                self._call_judge(
                    http_client=http_client,
                    model=resolved_judge_model,
                    system_prompt=system_prompt,
                    user_content=user_content,
                ),
                timeout=60.0,
            )
        except (asyncio.TimeoutError, Exception):
            return None  # Fail-open

        # Validate judge response shape
        if not isinstance(judge_response, dict):
            return None
        for required_key in ("violated_principles", "critique", "revision", "confidence"):
            if required_key not in judge_response:
                return None

        # PII-redact the revision text
        redacted_revision = redact(judge_response["revision"], pii_strictness)

        # Re-check revision against output rails
        synthetic_response = {
            "choices": [
                {
                    "message": {
                        "role": "assistant",
                        "content": redacted_revision,
                    }
                }
            ]
        }
        # Use a minimal tenant-like object with pii_strictness attribute
        class _MinimalTenant:
            pii_strictness = "minimal"  # avoid double-redacting during re-check

        try:
            revision_decision: GuardrailDecision = await self._guardrail_engine.check_output(
                response_data=synthetic_response,
                tenant=_MinimalTenant(),
            )
        except Exception:
            return None  # Fail-open

        # Find revision score for the triggering rail
        revision_score = 0.0
        for r in revision_decision.all_results:
            if r.rail == triggering_rail:
                revision_score = r.score
                break

        # Determine outcome
        rail_config = self._guardrail_engine._rails_config.get(triggering_rail)
        revision_critique_threshold = (
            rail_config.critique_threshold if rail_config and rail_config.critique_threshold is not None
            else critique_threshold_value
        )

        if revision_score >= revision_critique_threshold:
            outcome = "fallback_hard_block"
            fallback_hard_block = True
        else:
            outcome = "revised"
            fallback_hard_block = False

        return {
            "triggered_by": triggering_rail,
            "judge_model": resolved_judge_model,
            "original_score": triggering_score,
            "critique_threshold": critique_threshold_value,
            "judge_response": {
                "violated_principles": judge_response["violated_principles"],
                "critique": judge_response["critique"],
                "revision": redacted_revision,
                "confidence": judge_response["confidence"],
            },
            "revision_score": revision_score,
            "outcome": outcome,
            "fallback_hard_block": fallback_hard_block,
        }

    def _build_critique_prompt(
        self,
        output_text: str,
        triggering_rail: str,
        relevant_principles: list[Principle],
    ) -> tuple[str, str]:
        """Build system and user content for the judge model call.

        Args:
            output_text: The AI-generated text to evaluate.
            triggering_rail: Name of the guardrail that triggered critique.
            relevant_principles: Category-filtered enabled principles.

        Returns:
            (system_prompt, user_content) tuple.
        """
        system_prompt = (
            'You are a safety judge. Evaluate the following AI-generated text against the listed '
            'constitutional principles. Respond ONLY with valid JSON matching the schema: '
            '{"violated_principles": [<principle IDs>], "critique": "<explanation>", '
            '"revision": "<revised text>", "confidence": <0.0-1.0>}. '
            "The revision must address all identified violations while preserving the original "
            "intent as much as possible."
        )

        # Sort principles by priority descending
        sorted_principles = sorted(relevant_principles, key=lambda p: p.priority, reverse=True)
        principle_lines = "\n".join(f"- [{p.id}] {p.text}" for p in sorted_principles)

        user_content = (
            f"Constitutional principles:\n{principle_lines}\n\n"
            f"Triggering guardrail: {triggering_rail}\n\n"
            f"AI-generated text to evaluate:\n{output_text}"
        )

        return system_prompt, user_content

    async def _call_judge(
        self,
        http_client,
        model: str,
        system_prompt: str,
        user_content: str,
    ) -> dict:
        """POST to LiteLLM /v1/chat/completions and return parsed judge JSON.

        Args:
            http_client: httpx.AsyncClient with LiteLLM base_url set.
            model: Resolved judge model name.
            system_prompt: System message content.
            user_content: User message content.

        Returns:
            Parsed dict from judge JSON response.

        Raises:
            Exception: On HTTP error or JSON parse failure.
        """
        resp = await http_client.post(
            "/v1/chat/completions",
            json={
                "model": model,
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_content},
                ],
                "response_format": {"type": "json_object"},
            },
        )
        resp.raise_for_status()
        data = resp.json()
        content = data["choices"][0]["message"]["content"]
        return json.loads(content)
