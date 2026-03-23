"""lm-eval wrapper — run standard capability benchmarks via HarnessLM.

Wraps lm_eval.simple_evaluate with HarnessLM for MMLU, HellaSwag,
TruthfulQA, and GSM8K tasks.
"""
from __future__ import annotations


def run_lm_eval(
    gateway_url: str = "http://localhost:5000",
    litellm_url: str = "http://localhost:4000",
    api_key: str = "",
    model_name: str = "llama3.1",
    tasks: list[str] | None = None,
    limit: int | None = 100,
) -> dict:
    """Run lm-eval benchmarks via HarnessLM and return results.

    Args:
        gateway_url: Gateway URL for generate_until routing.
        litellm_url: LiteLLM URL (stored in HarnessLM, not used for
                     loglikelihood tasks).
        api_key: API key for gateway authentication.
        model_name: Model identifier passed to the gateway.
        tasks: List of lm-eval task names. Defaults to MMLU, HellaSwag,
               TruthfulQA, GSM8K.
        limit: Number of examples per task (None = all).

    Returns:
        Dict of task_name -> metrics from simple_evaluate results["results"].
    """
    import lm_eval
    from harness.eval.lm_model import HarnessLM

    if tasks is None:
        tasks = ["mmlu", "hellaswag", "truthfulqa_mc2", "gsm8k"]

    lm = HarnessLM(
        gateway_url=gateway_url,
        litellm_url=litellm_url,
        api_key=api_key,
        model=model_name,
    )

    results = lm_eval.simple_evaluate(
        model=lm,
        tasks=tasks,
        num_fewshot=0,
        limit=limit,
        log_samples=False,
    )

    return results["results"]
