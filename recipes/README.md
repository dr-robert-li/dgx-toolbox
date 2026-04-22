# DGX Toolbox — Local Recipe Directory

Sparkrun recipes maintained by dgx-toolbox for models and workloads that are not
(yet) in the official or community recipe registries.

## Using recipes from this directory

Sparkrun does not expose a `--recipe-path` flag. Recipe names are resolved
against registered registries (see `dgx-recipes list`) and the current
directory, or a direct path to a recipe YAML can be passed. The `vllm`
shell function in `example.bash_aliases` wraps `sparkrun run` and looks for
`~/dgx-toolbox/recipes/<name>.yaml` first, then falls back to sparkrun's
normal resolution:

```bash
# Via the `vllm` wrapper (resolves local recipes/ first, then registries)
vllm nemotron-3-nano-4b-bf16-vllm

# Pointing sparkrun directly at a recipe file
sparkrun run ~/dgx-toolbox/recipes/nemotron-3-nano-4b-bf16-vllm.yaml

# Recipe name resolved from a registered registry
sparkrun run qwen3.6
```

For upstream registries (official + community), use `dgx-recipes add` — that
runs `sparkrun registry add <URL>` under the hood, which reads the repo's
`.sparkrun/registry.yaml` manifest.

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
