"""Effective parameter scale and tier classification.

Maps raw model parameters through multiplier tables (quantization,
gradient checkpointing, sequence length, LoRA rank, optimizer) to
compute effective training memory footprint, then assigns a tier
with batch_cap and min_headroom_pct.
"""
from __future__ import annotations


# Multiplier tables — effective_params = raw_params * product(multipliers)
QUANT_MULTIPLIERS = {
    "fp32": 4.0,
    "fp16": 2.0,
    "bf16": 2.0,
    "int8": 1.0,
    "int4": 0.5,
    "nf4": 0.5,
}

GRAD_CKPT_MULTIPLIERS = {
    "none": 1.0,
    "full": 0.4,
    "selective": 0.6,
}


def _lora_multiplier(lora_rank: int) -> float:
    """LoRA rank 0 means full fine-tune (multiplier 1.0).

    Higher rank = more trainable params but still << full fine-tune.
    """
    if lora_rank == 0:
        return 1.0
    # Approximate: rank/1024 fraction of params are trainable
    return max(0.05, lora_rank / 1024.0)


def _seq_len_multiplier(seq_len: int) -> float:
    """Sequence length scaling: normalized to 2048 base."""
    return max(0.5, seq_len / 2048.0)


OPTIMIZER_MULTIPLIERS = {
    "adamw": 1.0,
    "adam": 1.0,
    "sgd": 0.5,
    "adafactor": 0.7,
    "lion": 0.75,
    "8bit-adam": 0.5,
}

# Tier thresholds (TELEM-08)
# Tiers ordered from smallest to largest; first match wins.
TIERS = [
    {"max_params": 1e9, "batch_cap": 64, "min_headroom_pct": 15},
    {"max_params": 13e9, "batch_cap": 16, "min_headroom_pct": 20},
    {"max_params": 30e9, "batch_cap": 8, "min_headroom_pct": 20},
    {"max_params": float("inf"), "batch_cap": 4, "min_headroom_pct": 25},
]


def compute(
    raw_params: float,
    quant_mode: str = "fp16",
    training_framework: str = "pytorch",
    gradient_checkpointing_mode: str = "none",
    lora_rank: int = 0,
    seq_len: int = 2048,
    optimizer: str = "adamw",
    model_weight_gb: float = 0.0,
) -> dict:
    """Compute effective parameter scale and assign tier.

    Returns dict with:
        effective_params: float — scaled parameter count
        tier: {"batch_cap": int, "min_headroom_pct": int}
    """
    quant_mult = QUANT_MULTIPLIERS.get(quant_mode, 2.0)
    grad_mult = GRAD_CKPT_MULTIPLIERS.get(gradient_checkpointing_mode, 1.0)
    lora_mult = _lora_multiplier(lora_rank)
    seq_mult = _seq_len_multiplier(seq_len)
    opt_mult = OPTIMIZER_MULTIPLIERS.get(optimizer, 1.0)

    effective = raw_params * quant_mult * grad_mult * lora_mult * seq_mult * opt_mult

    # Find tier based on raw_params (raw model size determines hardware requirements).
    # effective_params captures memory footprint for headroom calculation;
    # tier (batch_cap, min_headroom_pct) is determined by the model's parameter count
    # before quantization/LoRA adjustments.
    tier = TIERS[-1]  # default: largest
    for t in TIERS:
        if raw_params <= t["max_params"]:
            tier = t
            break

    return {
        "effective_params": float(effective),
        "tier": {
            "batch_cap": tier["batch_cap"],
            "min_headroom_pct": tier["min_headroom_pct"],
        },
    }
