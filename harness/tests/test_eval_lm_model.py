"""Tests for HarnessLM lm-eval Model subclass."""
from __future__ import annotations

import pytest
from unittest.mock import MagicMock, patch


class _FakeInstance:
    """Mock lm-eval Instance with .args = (context, gen_kwargs)."""
    def __init__(self, context: str, gen_kwargs: dict | None = None):
        self.args = (context, gen_kwargs or {"max_gen_toks": 64})


def _make_lm():
    """Create a HarnessLM without importing lm_eval (for unit tests)."""
    from harness.eval.lm_model import HarnessLM
    return HarnessLM(
        gateway_url="http://localhost:8080",
        litellm_url="http://localhost:4000",
        api_key="sk-test",
        model="llama3.1",
    )


def test_generate_until_routes_to_gateway():
    """generate_until POSTs to gateway_url/v1/chat/completions."""
    lm = _make_lm()
    fake_response = MagicMock()
    fake_response.json.return_value = {
        "choices": [{"message": {"content": "Sure, here is the answer."}}]
    }
    fake_response.raise_for_status = MagicMock()

    with patch("harness.eval.lm_model.http_requests.post", return_value=fake_response) as mock_post:
        results = lm.generate_until([_FakeInstance("Hello")])

    assert mock_post.called
    call_url = mock_post.call_args[0][0]
    assert call_url == "http://localhost:8080/v1/chat/completions"
    assert results == ["Sure, here is the answer."]


def test_loglikelihood_raises():
    """loglikelihood raises NotImplementedError."""
    lm = _make_lm()
    with pytest.raises(NotImplementedError):
        lm.loglikelihood([])


def test_loglikelihood_rolling_raises():
    """loglikelihood_rolling raises NotImplementedError."""
    lm = _make_lm()
    with pytest.raises(NotImplementedError):
        lm.loglikelihood_rolling([])
