"""HarnessLM — lm-eval LM subclass with split routing.

Routes generate_until to gateway URL (POST /v1/chat/completions).
Routes loglikelihood to the upstream OpenAI-compatible proxy URL (raises
NotImplementedError with guidance). In this project that proxy is sparkrun
(https://github.com/spark-arena/sparkrun), which binds :4000 by default — the
same port the legacy LiteLLM launcher used — so no wire-level changes are
required. The ``litellm_url`` kwarg is kept for backward compatibility with
existing callers; it refers to whatever OpenAI-compatible proxy is running
locally, sparkrun or otherwise.

Import is conditional so the module loads even if lm-eval is not installed.
"""
from __future__ import annotations

import requests as http_requests

try:
    from lm_eval.api.model import LM as _BaseLM
except ImportError:
    _BaseLM = object  # type: ignore[misc,assignment]


class HarnessLM(_BaseLM):
    """lm-eval LM subclass with split routing for DGX harness.

    generate_until -> gateway_url/v1/chat/completions (safety guardrails)
    loglikelihood  -> raises NotImplementedError (hit the upstream proxy's
                      local-completions endpoint directly, e.g. sparkrun on
                      :4000; the ``litellm_url`` kwarg is kept as the name for
                      backward compatibility)
    """

    def __init__(
        self,
        gateway_url: str = "http://localhost:5000",
        litellm_url: str = "http://localhost:4000",
        api_key: str = "",
        model: str = "llama3.1",
    ) -> None:
        self.gateway_url = gateway_url.rstrip("/")
        self.litellm_url = litellm_url.rstrip("/")
        self.api_key = api_key
        self.model = model

    def generate_until(self, requests) -> list[str]:
        """Send generate_until requests to the gateway chat completions endpoint.

        Args:
            requests: Iterable of lm-eval Instance objects. Each has
                      .args = (context_str, gen_kwargs_dict).

        Returns:
            List of generated text strings.
        """
        results: list[str] = []
        for instance in requests:
            context, gen_kwargs = instance.args
            max_tokens = gen_kwargs.get("max_gen_toks", 256) if gen_kwargs else 256
            stop = gen_kwargs.get("until", None) if gen_kwargs else None

            payload: dict = {
                "model": self.model,
                "messages": [{"role": "user", "content": context}],
                "max_tokens": max_tokens,
            }
            if stop:
                payload["stop"] = stop

            response = http_requests.post(
                f"{self.gateway_url}/v1/chat/completions",
                headers={"Authorization": f"Bearer {self.api_key}"},
                json=payload,
                timeout=60,
            )
            response.raise_for_status()
            content = response.json()["choices"][0]["message"]["content"]
            results.append(content)

        return results

    def loglikelihood(self, requests) -> list:
        """Not supported via gateway — use LiteLLM directly.

        Raises:
            NotImplementedError: Always raised. loglikelihood requires
                /v1/completions with logprobs=True. Use generate_until tasks
                or run lm-eval local-completions against LiteLLM :4000 directly.
        """
        raise NotImplementedError(
            "loglikelihood requires /v1/completions with logprobs=True; "
            "use generate_until tasks or run lm-eval local-completions "
            "against LiteLLM :4000 directly"
        )

    def loglikelihood_rolling(self, requests) -> list:
        """Not supported via gateway.

        Raises:
            NotImplementedError: Always raised.
        """
        raise NotImplementedError(
            "loglikelihood_rolling requires /v1/completions with logprobs=True; "
            "use generate_until tasks or run lm-eval local-completions "
            "against LiteLLM :4000 directly"
        )
