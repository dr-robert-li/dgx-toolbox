"""Training failure classification from telemetry snapshots.

Classifies training outcomes as: clean, oom, hang, thermal, or pressure.
HANG classification intentionally omits batch_cap to prevent incorrect
batch backoff on dataloader deadlocks (TELEM-14).
"""
from __future__ import annotations


def classify_failure(
    final_readings: dict,
    exit_code: int,
    training_completed: bool,
) -> dict:
    """Classify a training run outcome from its final telemetry snapshot.

    Args:
        final_readings: Dict with keys mem_available_gb, gpu_util_pct,
            cpu_pct, temperature_c, duration_at_state_s.
        exit_code: Process exit code (0 = normal).
        training_completed: Whether the training loop finished normally.

    Returns:
        Dict with "classification" (str) and "evidence" (dict).
        HANG returns never contain a "batch_cap" key.
    """
    if training_completed and exit_code == 0:
        return {"classification": "clean", "evidence": {}}

    mem_gb = final_readings.get("mem_available_gb", 99.0)
    gpu_util = final_readings.get("gpu_util_pct", 100)
    cpu_pct = final_readings.get("cpu_pct", 0)
    temp_c = final_readings.get("temperature_c", 0)
    duration_s = final_readings.get("duration_at_state_s", 0)

    # OOM: GPU idle + near-zero memory
    if gpu_util < 10 and mem_gb < 1.0:
        return {
            "classification": "oom",
            "evidence": {"mem_available_gb": mem_gb, "gpu_util_pct": gpu_util},
        }

    # HANG: GPU idle + CPU saturated + 60s sustained + memory healthy
    # CRITICAL: no batch_cap in this return (TELEM-14)
    if gpu_util < 10 and cpu_pct > 90 and duration_s >= 60 and mem_gb > 10.0:
        return {
            "classification": "hang",
            "evidence": {
                "gpu_util_pct": gpu_util,
                "cpu_pct": cpu_pct,
                "duration_s": duration_s,
                "mem_available_gb": mem_gb,
            },
            # No "batch_cap" key — this is intentional and load-bearing (TELEM-14)
        }

    # Thermal: sustained high temperature
    if temp_c >= 85:
        return {"classification": "thermal", "evidence": {"temperature_c": temp_c}}

    # Pressure: low memory but not full OOM
    if mem_gb < 3.0:
        return {"classification": "pressure", "evidence": {"mem_available_gb": mem_gb}}

    return {"classification": "clean", "evidence": {}}
