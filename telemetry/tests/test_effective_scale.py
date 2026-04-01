"""Tests for effective_scale.compute() (TELEM-07, TELEM-08)."""

import pytest


def test_tier_1b():
    """compute with 0.5B params (fp16, default) returns tier with batch_cap=64, min_headroom_pct=15."""
    from telemetry.effective_scale import compute

    result = compute(raw_params=0.5e9, quant_mode="fp16")
    assert "effective_params" in result
    assert "tier" in result
    tier = result["tier"]
    assert tier["batch_cap"] == 64, f"Expected batch_cap=64, got {tier['batch_cap']}"
    assert tier["min_headroom_pct"] == 15, (
        f"Expected min_headroom_pct=15, got {tier['min_headroom_pct']}"
    )


def test_tier_1_13b():
    """compute with 7B params returns tier with batch_cap=16, min_headroom_pct=20."""
    from telemetry.effective_scale import compute

    result = compute(raw_params=7e9, quant_mode="fp16")
    tier = result["tier"]
    assert tier["batch_cap"] == 16, f"Expected batch_cap=16, got {tier['batch_cap']}"
    assert tier["min_headroom_pct"] == 20, (
        f"Expected min_headroom_pct=20, got {tier['min_headroom_pct']}"
    )


def test_tier_13_30b():
    """compute with 20B params returns tier with batch_cap=8, min_headroom_pct=20."""
    from telemetry.effective_scale import compute

    result = compute(raw_params=20e9, quant_mode="fp16")
    tier = result["tier"]
    assert tier["batch_cap"] == 8, f"Expected batch_cap=8, got {tier['batch_cap']}"
    assert tier["min_headroom_pct"] == 20, (
        f"Expected min_headroom_pct=20, got {tier['min_headroom_pct']}"
    )


def test_tier_30b_plus():
    """compute with 40B params returns tier with batch_cap=4, min_headroom_pct=25."""
    from telemetry.effective_scale import compute

    result = compute(raw_params=40e9, quant_mode="fp16")
    tier = result["tier"]
    assert tier["batch_cap"] == 4, f"Expected batch_cap=4, got {tier['batch_cap']}"
    assert tier["min_headroom_pct"] == 25, (
        f"Expected min_headroom_pct=25, got {tier['min_headroom_pct']}"
    )


def test_quant_multiplier():
    """int4 quantization produces lower effective_params than fp16."""
    from telemetry.effective_scale import compute

    result_fp16 = compute(raw_params=7e9, quant_mode="fp16")
    result_int4 = compute(raw_params=7e9, quant_mode="int4")
    assert result_int4["effective_params"] < result_fp16["effective_params"], (
        "int4 should produce lower effective_params than fp16"
    )


def test_lora_rank_multiplier():
    """lora_rank=16 produces lower effective_params than lora_rank=0 (full fine-tune)."""
    from telemetry.effective_scale import compute

    result_full = compute(raw_params=7e9, lora_rank=0)
    result_lora = compute(raw_params=7e9, lora_rank=16)
    assert result_lora["effective_params"] < result_full["effective_params"], (
        "LoRA (rank=16) should produce lower effective_params than full fine-tune (rank=0)"
    )


def test_returns_effective_params_and_tier():
    """Result dict has 'effective_params' (float) and 'tier' (dict with batch_cap and min_headroom_pct)."""
    from telemetry.effective_scale import compute

    result = compute(raw_params=7e9)
    assert isinstance(result["effective_params"], float), (
        f"effective_params should be float, got {type(result['effective_params'])}"
    )
    assert isinstance(result["tier"], dict)
    assert "batch_cap" in result["tier"]
    assert "min_headroom_pct" in result["tier"]
