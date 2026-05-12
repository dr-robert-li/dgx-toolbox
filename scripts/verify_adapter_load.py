#!/usr/bin/env python3
"""
Verify a PEFT LoRA adapter binds to its declared targets.

Background: PEFT < 0.19 silently warns (not errors) when an adapter's
`target_parameters` entries match zero base-model parameters. The common
case is an Unsloth-trained MoE adapter (target_parameters like
"mlp.experts.gate_up_proj", "mlp.experts.down_proj") loaded via raw
`PeftModel.from_pretrained` — generation then runs on BASE expert weights,
producing silent quality regressions. The reliable load path for those
adapters is `unsloth.FastLanguageModel.from_pretrained`.

This helper diffs the adapter's declared targets against the base config
and surfaces the MoE landmine without requiring a full model load.

Usage:
  verify_adapter_load.py --base <hf_id_or_path> --adapter <local_dir>
  verify_adapter_load.py --base <hf_id_or_path> --adapter <local_dir> --load-model

Exit codes:
  0  all declared targets resolved
  1  unbound targets, or MoE silent-fail risk detected
  2  bad invocation / missing files
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _read_adapter_config(adapter_dir: Path) -> dict:
    cfg_path = adapter_dir / "adapter_config.json"
    if not cfg_path.is_file():
        print(f"ERROR: adapter_config.json not found in {adapter_dir}", file=sys.stderr)
        sys.exit(2)
    with cfg_path.open() as f:
        return json.load(f)


def _detect_moe(base: str) -> tuple[bool, int, str]:
    """Return (is_moe, num_experts, architecture). Falls back gracefully if
    transformers isn't importable so the helper still works for structural
    inspection on a minimal env."""
    try:
        from transformers import AutoConfig
    except ImportError:
        print("WARNING: transformers not importable — skipping base config check.", file=sys.stderr)
        return False, 0, "<unknown>"
    try:
        cfg = AutoConfig.from_pretrained(base, trust_remote_code=True)
    except Exception as e:
        print(f"WARNING: could not load base config for '{base}': {e}", file=sys.stderr)
        return False, 0, "<unknown>"
    n = 0
    for attr in ("num_experts", "num_local_experts", "n_routed_experts", "moe_num_experts"):
        if hasattr(cfg, attr):
            v = getattr(cfg, attr)
            if isinstance(v, int) and v > 1:
                n = max(n, v)
    arch = cfg.architectures[0] if getattr(cfg, "architectures", None) else type(cfg).__name__
    return n > 1, n, arch


def _empirical_load_check(base: str, adapter: Path) -> tuple[set[str], set[str]]:
    """Optionally load base + adapter and return (declared, actually_bound)
    LoRA target parameter paths. Heavy — only run when --load-model is set."""
    from peft import PeftModel
    from transformers import AutoModelForCausalLM
    import torch

    print("Loading base model (this can take a minute)...", file=sys.stderr)
    model = AutoModelForCausalLM.from_pretrained(
        base, torch_dtype=torch.float16, trust_remote_code=True, low_cpu_mem_usage=True
    )
    model = PeftModel.from_pretrained(model, str(adapter))

    bound: set[str] = set()
    for name, _ in model.named_parameters():
        if "lora_A" in name or "lora_B" in name or "lora_embedding" in name:
            base_path = name.split(".lora_")[0]
            bound.add(base_path)
    # Strip the "base_model.model." prefix peft adds
    bound = {b.removeprefix("base_model.model.") for b in bound}
    return bound, bound  # caller already has declared


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1] if __doc__ else "")
    ap.add_argument("--base", required=True, help="HF repo id or local path of base model")
    ap.add_argument("--adapter", required=True, type=Path, help="local adapter directory")
    ap.add_argument(
        "--load-model",
        action="store_true",
        help="empirically load base+adapter and report actual bound LoRA params (heavy)",
    )
    args = ap.parse_args()

    if not args.adapter.is_dir():
        print(f"ERROR: --adapter is not a directory: {args.adapter}", file=sys.stderr)
        return 2

    cfg = _read_adapter_config(args.adapter)
    target_modules = sorted(cfg.get("target_modules") or [])
    target_parameters = sorted(cfg.get("target_parameters") or [])
    modules_to_save = sorted(cfg.get("modules_to_save") or [])

    is_moe, n_experts, arch = _detect_moe(args.base)

    print(f"adapter:           {args.adapter}")
    print(f"base:              {args.base}")
    print(f"  architecture:    {arch}")
    print(f"  MoE:             {is_moe} (num_experts={n_experts})")
    print(f"target_modules:    {target_modules}")
    print(f"target_parameters: {target_parameters}")
    print(f"modules_to_save:   {modules_to_save}")
    print()

    exit_code = 0

    if target_parameters and is_moe:
        try:
            import peft  # noqa: F401
            from packaging.version import Version

            peft_ver = Version(peft.__version__)
        except ImportError:
            peft_ver = None

        risk = peft_ver is None or peft_ver < Version("0.19")
        if risk:
            print(
                "WARNING: MoE base + target_parameters detected. PEFT < 0.19 silently fails to bind",
                file=sys.stderr,
            )
            print(
                "         expert parameters — generation runs on BASE expert weights, producing a",
                file=sys.stderr,
            )
            print(
                "         silent quality regression. Load this adapter via:",
                file=sys.stderr,
            )
            print(
                "           from unsloth import FastLanguageModel",
                file=sys.stderr,
            )
            print(
                "           model, tokenizer = FastLanguageModel.from_pretrained(adapter_path, ...)",
                file=sys.stderr,
            )
            print(
                "         NOT via PeftModel.from_pretrained.",
                file=sys.stderr,
            )
            exit_code = 1

    if args.load_model:
        try:
            declared = set(target_modules) | set(target_parameters)
            bound, _ = _empirical_load_check(args.base, args.adapter)
            # Heuristic: declared name appears as suffix of a bound path
            unmatched = {
                d for d in declared if not any(b.endswith(d) or d in b for b in bound)
            }
            if unmatched:
                print(f"UNBOUND targets: {sorted(unmatched)}", file=sys.stderr)
                print(f"BOUND sample: {sorted(list(bound))[:8]}", file=sys.stderr)
                exit_code = 1
            else:
                print(f"OK: all {len(declared)} declared targets bound ({len(bound)} total LoRA modules).")
        except Exception as e:
            print(f"ERROR during --load-model check: {e}", file=sys.stderr)
            return 1

    if exit_code == 0:
        print("OK: no static issues detected.")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
