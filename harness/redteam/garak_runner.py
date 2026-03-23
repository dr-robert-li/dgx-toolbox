"""garak subprocess wrapper for vulnerability scanning."""
from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path


async def run_garak_scan(
    profile_config_path: str,
    api_key: str,
    report_dir: str,
    job_id: str,
    model_name: str = "harness-gateway",
    probes: str | None = None,
) -> dict:
    """Run garak as async subprocess and return parsed results.

    Uses asyncio.create_subprocess_exec (NOT subprocess.run) to avoid blocking
    the event loop during potentially long-running scans.

    Args:
        profile_config_path: Path to garak YAML config (e.g. redteam_quick.yaml).
        api_key: Tenant API key for the gateway — set as OPENAICOMPATIBLE_API_KEY env var.
        report_dir: Directory where garak writes report files.
        job_id: Unique job ID used as report filename prefix.
        model_name: Model name for --target_name flag.
        probes: Comma-separated probe list for --probes flag (optional).

    Returns:
        Dict with keys: exit_code, stdout, stderr, scores, report_path.
    """
    # Ensure report dir exists
    os.makedirs(report_dir, exist_ok=True)

    env = {**os.environ, "OPENAICOMPATIBLE_API_KEY": api_key}
    report_prefix = os.path.join(report_dir, job_id)

    cmd = [
        "python", "-m", "garak",
        "--config", profile_config_path,
        "--report_prefix", report_prefix,
    ]
    if probes:
        cmd.extend(["--probes", probes])

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env=env,
    )
    stdout, stderr = await proc.communicate()

    report_path = f"{report_prefix}.report.jsonl"
    scores = parse_garak_report(report_path)

    return {
        "exit_code": proc.returncode,
        "stdout": stdout.decode(errors="replace")[-2000:],  # Truncate for storage
        "stderr": stderr.decode(errors="replace")[-2000:],
        "scores": scores,
        "report_path": report_path,
    }


def parse_garak_report(report_path: str) -> dict:
    """Parse garak JSONL report file and extract probe scores.

    Args:
        report_path: Path to {job_id}.report.jsonl file.

    Returns:
        Dict of probe_name -> {"passed": int, "total": int, "pass_rate": float}.
    """
    scores = {}
    try:
        with open(report_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                entry = json.loads(line)
                if entry.get("entry_type") == "eval":
                    probe = entry.get("probe", "unknown")
                    passed = entry.get("passed", 0)
                    total = max(entry.get("total", 1), 1)
                    scores[probe] = {
                        "passed": passed,
                        "total": total,
                        "pass_rate": round(passed / total, 4),
                    }
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    return scores
