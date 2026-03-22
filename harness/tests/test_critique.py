"""Unit tests for CritiqueEngine — critique-revise loop, fallback, benign bypass,
judge model ID resolution, PII redaction, category filtering, and timeout handling.

TDD: These tests are written before the implementation. They describe the exact
behaviour expected from CritiqueEngine.run_critique_loop().
"""
from __future__ import annotations

import asyncio
import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from harness.critique.constitution import ConstitutionConfig, Principle
from harness.config.rail_loader import RailConfig
from harness.guards.types import GuardrailDecision, RailResult


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def make_constitution(judge_model: str = "default") -> ConstitutionConfig:
    """Return a ConstitutionConfig with 4 principles (2 safety, 1 accuracy, 1 helpfulness)."""
    return ConstitutionConfig(
        judge_model=judge_model,
        principles=[
            Principle(
                id="P-SAFETY-1",
                text="Do not produce harmful content",
                category="safety",
                priority=0.9,
                enabled=True,
            ),
            Principle(
                id="P-SAFETY-2",
                text="Do not provide instructions for illegal activities",
                category="safety",
                priority=0.8,
                enabled=True,
            ),
            Principle(
                id="P-ACCURACY",
                text="Ensure factual accuracy",
                category="accuracy",
                priority=0.7,
                enabled=True,
            ),
            Principle(
                id="P-HELPFULNESS",
                text="Be as helpful as possible",
                category="helpfulness",
                priority=0.5,
                enabled=True,
            ),
        ],
    )


def make_guardrail_engine(critique_threshold: float = 0.4) -> MagicMock:
    """Return a mock GuardrailEngine with _rails_config containing RailConfig objects."""
    engine = MagicMock()
    engine._rails_config = {
        "self_check_output": RailConfig(
            name="self_check_output",
            enabled=True,
            threshold=0.7,
            critique_threshold=critique_threshold,
            refusal_mode="hard_block",
        ),
        "jailbreak_output": RailConfig(
            name="jailbreak_output",
            enabled=True,
            threshold=0.7,
            critique_threshold=critique_threshold,
            refusal_mode="hard_block",
        ),
        "sensitive_data_output": RailConfig(
            name="sensitive_data_output",
            enabled=True,
            threshold=0.7,
            critique_threshold=critique_threshold,
            refusal_mode="hard_block",
        ),
    }
    return engine


def make_http_client(revision: str = "This is the safe revised response.") -> AsyncMock:
    """Return an AsyncMock http_client that returns a judge JSON response."""
    client = AsyncMock()
    judge_response = {
        "choices": [
            {
                "message": {
                    "role": "assistant",
                    "content": json.dumps({
                        "violated_principles": ["P-SAFETY-1"],
                        "critique": "The response contains potentially harmful content.",
                        "revision": revision,
                        "confidence": 0.85,
                    }),
                }
            }
        ]
    }
    mock_resp = MagicMock()
    mock_resp.json.return_value = judge_response
    mock_resp.raise_for_status = MagicMock()
    client.post.return_value = mock_resp
    return client


def make_output_results(score: float, rail: str = "self_check_output") -> list[RailResult]:
    """Return a list with a single RailResult for the given score and rail."""
    return [
        RailResult(
            rail=rail,
            result="pass" if score < 0.7 else "block",
            score=score,
            threshold=0.7,
        )
    ]


def make_revision_decision(revision_score: float) -> GuardrailDecision:
    """Return a GuardrailDecision for a re-check of the revised text."""
    return GuardrailDecision(
        blocked=revision_score >= 0.7,
        refusal_mode="hard_block" if revision_score >= 0.7 else None,
        triggering_rail="self_check_output" if revision_score >= 0.7 else None,
        all_results=[
            RailResult(
                rail="self_check_output",
                result="block" if revision_score >= 0.7 else "pass",
                score=revision_score,
                threshold=0.7,
            )
        ],
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_critique_loop_triggered():
    """High-risk output (score >= critique_threshold < threshold) triggers critique loop."""
    from harness.critique.engine import CritiqueEngine

    constitution = make_constitution()
    guardrail_engine = make_guardrail_engine(critique_threshold=0.4)
    guardrail_engine.check_output = AsyncMock(
        return_value=make_revision_decision(revision_score=0.1)
    )
    http_client = make_http_client()

    engine = CritiqueEngine(constitution=constitution, guardrail_engine=guardrail_engine)
    output_results = make_output_results(score=0.55)  # >= 0.4 critique_threshold, < 0.7 threshold

    result = await engine.run_critique_loop(
        response_data={"choices": [{"message": {"content": "Borderline output."}}]},
        output_results=output_results,
        request_model="llama3.1",
        http_client=http_client,
    )

    assert result is not None
    assert result["triggered_by"] == "self_check_output"
    assert result["judge_model"] == "llama3.1"  # resolved from "default"
    assert result["original_score"] == pytest.approx(0.55)
    assert result["critique_threshold"] == pytest.approx(0.4)
    assert "judge_response" in result
    assert result["outcome"] == "revised"


@pytest.mark.asyncio
async def test_critique_revision_returned():
    """When judge returns a valid revision that re-checks below critique_threshold, outcome='revised'."""
    from harness.critique.engine import CritiqueEngine

    constitution = make_constitution()
    guardrail_engine = make_guardrail_engine(critique_threshold=0.4)
    guardrail_engine.check_output = AsyncMock(
        return_value=make_revision_decision(revision_score=0.1)
    )
    http_client = make_http_client(revision="Revised safe response without harmful content.")

    engine = CritiqueEngine(constitution=constitution, guardrail_engine=guardrail_engine)
    output_results = make_output_results(score=0.55)

    result = await engine.run_critique_loop(
        response_data={"choices": [{"message": {"content": "Borderline output."}}]},
        output_results=output_results,
        request_model="llama3.1",
        http_client=http_client,
    )

    assert result is not None
    assert result["outcome"] == "revised"
    assert len(result["judge_response"]["revision"]) > 0


@pytest.mark.asyncio
async def test_critique_fallback_hard_block():
    """If revision still scores >= critique_threshold on re-check, outcome='fallback_hard_block'."""
    from harness.critique.engine import CritiqueEngine

    constitution = make_constitution()
    guardrail_engine = make_guardrail_engine(critique_threshold=0.4)
    # Revision re-check scores high — still risky
    guardrail_engine.check_output = AsyncMock(
        return_value=make_revision_decision(revision_score=0.55)
    )
    http_client = make_http_client(revision="Still somewhat unsafe revision.")

    engine = CritiqueEngine(constitution=constitution, guardrail_engine=guardrail_engine)
    output_results = make_output_results(score=0.55)

    result = await engine.run_critique_loop(
        response_data={"choices": [{"message": {"content": "Borderline output."}}]},
        output_results=output_results,
        request_model="llama3.1",
        http_client=http_client,
    )

    assert result is not None
    assert result["outcome"] == "fallback_hard_block"
    assert result["fallback_hard_block"] is True


@pytest.mark.asyncio
async def test_benign_no_critique():
    """Output with score below critique_threshold returns None — no critique needed."""
    from harness.critique.engine import CritiqueEngine

    constitution = make_constitution()
    guardrail_engine = make_guardrail_engine(critique_threshold=0.4)
    http_client = make_http_client()

    engine = CritiqueEngine(constitution=constitution, guardrail_engine=guardrail_engine)
    output_results = make_output_results(score=0.2)  # < 0.4 critique_threshold

    result = await engine.run_critique_loop(
        response_data={"choices": [{"message": {"content": "Safe benign response."}}]},
        output_results=output_results,
        request_model="llama3.1",
        http_client=http_client,
    )

    assert result is None
    # Judge should NOT be called for benign output
    http_client.post.assert_not_called()


@pytest.mark.asyncio
async def test_judge_model_id_in_trace():
    """When judge_model='default' and request_model='llama3.1', trace has judge_model='llama3.1'."""
    from harness.critique.engine import CritiqueEngine

    constitution = make_constitution(judge_model="default")
    guardrail_engine = make_guardrail_engine(critique_threshold=0.4)
    guardrail_engine.check_output = AsyncMock(
        return_value=make_revision_decision(revision_score=0.1)
    )
    http_client = make_http_client()

    engine = CritiqueEngine(constitution=constitution, guardrail_engine=guardrail_engine)
    output_results = make_output_results(score=0.55)

    result = await engine.run_critique_loop(
        response_data={"choices": [{"message": {"content": "Borderline output."}}]},
        output_results=output_results,
        request_model="llama3.1",
        http_client=http_client,
    )

    assert result is not None
    assert result["judge_model"] == "llama3.1"  # resolved, not "default"


@pytest.mark.asyncio
async def test_judge_model_configured():
    """When judge_model is explicitly set, trace uses that model name."""
    from harness.critique.engine import CritiqueEngine

    constitution = make_constitution(judge_model="llama3.1-70b")
    guardrail_engine = make_guardrail_engine(critique_threshold=0.4)
    guardrail_engine.check_output = AsyncMock(
        return_value=make_revision_decision(revision_score=0.1)
    )
    http_client = make_http_client()

    engine = CritiqueEngine(constitution=constitution, guardrail_engine=guardrail_engine)
    output_results = make_output_results(score=0.55)

    result = await engine.run_critique_loop(
        response_data={"choices": [{"message": {"content": "Borderline output."}}]},
        output_results=output_results,
        request_model="llama3.1",  # request model — should be ignored
        http_client=http_client,
    )

    assert result is not None
    assert result["judge_model"] == "llama3.1-70b"


@pytest.mark.asyncio
async def test_pii_redacted_in_critique():
    """Revision text in cai_critique has PII redacted (email replaced with [EMAIL])."""
    from harness.critique.engine import CritiqueEngine

    constitution = make_constitution()
    guardrail_engine = make_guardrail_engine(critique_threshold=0.4)
    guardrail_engine.check_output = AsyncMock(
        return_value=make_revision_decision(revision_score=0.1)
    )
    # Judge returns revision containing an email address
    http_client = make_http_client(revision="Contact us at user@example.com for more info.")

    engine = CritiqueEngine(constitution=constitution, guardrail_engine=guardrail_engine)
    output_results = make_output_results(score=0.55)

    result = await engine.run_critique_loop(
        response_data={"choices": [{"message": {"content": "Borderline output."}}]},
        output_results=output_results,
        request_model="llama3.1",
        http_client=http_client,
    )

    assert result is not None
    assert "user@example.com" not in result["judge_response"]["revision"]
    assert "[EMAIL]" in result["judge_response"]["revision"]


@pytest.mark.asyncio
async def test_critique_prompt_relevant_principles_only():
    """For self_check_output trigger, prompt includes safety+accuracy but NOT helpfulness."""
    from harness.critique.engine import CritiqueEngine

    constitution = make_constitution()
    guardrail_engine = make_guardrail_engine(critique_threshold=0.4)
    guardrail_engine.check_output = AsyncMock(
        return_value=make_revision_decision(revision_score=0.1)
    )

    captured_calls = []

    async def mock_post(url, **kwargs):
        captured_calls.append(kwargs)
        mock_resp = MagicMock()
        mock_resp.json.return_value = {
            "choices": [
                {
                    "message": {
                        "role": "assistant",
                        "content": json.dumps({
                            "violated_principles": ["P-SAFETY-1"],
                            "critique": "Unsafe content.",
                            "revision": "Safe revision.",
                            "confidence": 0.9,
                        }),
                    }
                }
            ]
        }
        mock_resp.raise_for_status = MagicMock()
        return mock_resp

    http_client = AsyncMock()
    http_client.post = mock_post

    engine = CritiqueEngine(constitution=constitution, guardrail_engine=guardrail_engine)
    output_results = make_output_results(score=0.55)

    result = await engine.run_critique_loop(
        response_data={"choices": [{"message": {"content": "Borderline output."}}]},
        output_results=output_results,
        request_model="llama3.1",
        http_client=http_client,
    )

    assert result is not None
    assert len(captured_calls) == 1
    # Inspect the messages sent to judge
    messages = captured_calls[0]["json"]["messages"]
    user_content = next(m["content"] for m in messages if m["role"] == "user")
    assert "P-SAFETY-1" in user_content
    assert "P-ACCURACY" in user_content
    assert "P-HELPFULNESS" not in user_content


@pytest.mark.asyncio
async def test_judge_call_timeout():
    """When judge HTTP call times out, run_critique_loop returns None (fail-open)."""
    from harness.critique.engine import CritiqueEngine

    constitution = make_constitution()
    guardrail_engine = make_guardrail_engine(critique_threshold=0.4)

    http_client = AsyncMock()
    http_client.post.side_effect = asyncio.TimeoutError()

    engine = CritiqueEngine(constitution=constitution, guardrail_engine=guardrail_engine)
    output_results = make_output_results(score=0.55)

    result = await engine.run_critique_loop(
        response_data={"choices": [{"message": {"content": "Borderline output."}}]},
        output_results=output_results,
        request_model="llama3.1",
        http_client=http_client,
    )

    assert result is None
