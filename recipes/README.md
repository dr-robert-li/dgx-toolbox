# DGX Toolbox — Local Recipe Directory

Sparkrun recipes maintained by dgx-toolbox for models and workloads that are not
(yet) in the official or community recipe registries.

## Registering this directory with sparkrun

```bash
# One-time, per-host
sparkrun registry add dgx-toolbox-local ~/dgx-toolbox/recipes --type local
sparkrun registry list
```

## Running recipes from here

```bash
# Via registered local registry
sparkrun run nemotron-3-nano-4b-bf16-vllm

# Or ad-hoc by path
sparkrun run nemotron-3-nano-4b-bf16-vllm --recipe-path ~/dgx-toolbox/recipes/
```

## Authoring conventions

- Use `recipe_version: "2"` (v2 schema — supports mods, env overrides, and SAF variables).
- Pin the container image to a **Blackwell-tested** tag. As of 2026-04, the
  `ghcr.io/spark-arena/dgx-vllm-eugr-nightly:latest` image is the reference build
  with sm_121 kernels. Do **not** use `vllm/vllm-openai:latest` without verifying
  it ships sm_121 kernels — JIT compile on first run otherwise.
- Keep `gpu_memory_utilization` ≤ 0.8 to leave headroom for UMA sharing with
  harness, Open-WebUI, telemetry, and other containers on the single DGX Spark.
- Set `max_model_len` based on your KV-cache budget, not just the model's max.
- When adding a new recipe, also add a smoke entry to
  `scripts/test-sparkrun-integration.sh`.

## Current recipes

| File | Model | Runtime | Notes |
|------|-------|---------|-------|
| `nemotron-3-nano-4b-bf16-vllm.yaml` | `nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16` | vLLM | Replaces legacy `example.vllm-model` default. |
| `eval-checkpoint.yaml` | (templated, set `MODEL` env var) | vLLM | Ephemeral eval workload for `scripts/eval-checkpoint.sh`. |

## Upstream references

- Sparkrun recipe schema — https://github.com/spark-arena/sparkrun/blob/main/docs
- Official registry — https://github.com/spark-arena/recipe-registry
- Community registry — https://github.com/spark-arena/community-recipe-registry
