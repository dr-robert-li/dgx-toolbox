# Phase 13: GPU Telemetry Primitives - Research

**Researched:** 2026-04-01
**Domain:** NVML/pynvml bindings, /proc/meminfo UMA memory, Python package structure, training telemetry
**Confidence:** HIGH

## Summary

Phase 13 builds a standalone Python package at `dgx-toolbox/telemetry/` that any training project can `pip install -e` to get hardware telemetry, memory headroom calculations, failure classification, and proven-batch-config anchoring — all without invoking subprocess or requiring a physical GPU at import time.

The primary hardware challenge is the GB10 Unified Memory Architecture (UMA): `nvmlDeviceGetMemoryInfo` raises `NVMLError_NotSupported` on this device, so `/proc/meminfo` MemAvailable is the authoritative memory source throughout. The sampler wraps all NVML calls with graceful fallbacks so the same code runs in CI (no GPU, no libnvidia-ml.so.1) and on the DGX Spark (full hardware). `nvidia-ml-py>=13.595,<14` is the correct package — the legacy `pynvml` package exposes the same `import pynvml` namespace and must not be co-installed.

The phase builds six modules in a fixed order (FailureClassifier → GPUSampler → UMAMemModel → EffectiveScale → AnchorStore → ProbeProtocol) followed by two integration touchpoints (status.sh GPU block, dgx_toolbox.py bridge). All test assertions must pass without GPU hardware, which drives the mock-mode requirement from day one.

**Primary recommendation:** Use `nvidia-ml-py==13.595.45` (latest), catch `NVMLError` at every NVML call site with graceful fallback, and gate the entire NVML init block behind a try/except that sets `_mock_mode = True` when `libnvidia-ml.so.1` is absent.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| TELEM-01 | `from telemetry.sampler import GPUSampler`; `sample()` returns watts, temp, util, MemAvailable, page cache; no subprocess | NVML API surface verified: `nvmlDeviceGetPowerUsage` (milliwatts, divide by 1000), `nvmlDeviceGetTemperature(handle, NVML_TEMPERATURE_GPU)`, `nvmlDeviceGetUtilizationRates(handle).gpu`; /proc/meminfo Cached field for page cache |
| TELEM-02 | pynvml-only for GPU metrics; /proc/meminfo MemAvailable fallback when nvmlDeviceGetMemoryInfo returns N/A | `NVML_ERROR_NOT_SUPPORTED = 3` confirmed; catch `NVMLError` subclass; always read MemAvailable not MemFree |
| TELEM-03 | `sample()` returns complete dict; `append_jsonl(path)` appends NDJSON record | Standard Python json + pathlib; newline-append pattern |
| TELEM-04 | Mock mode: initializes and runs without GPU hardware | `NVMLError_LibraryNotFound` (NVML_ERROR_LIBRARY_NOT_FOUND=12) raised when libnvidia-ml.so.1 absent; set `_mock=True` flag in except block |
| TELEM-05 | `sample_baseline()` drops page cache then returns MemAvailable, Cached, idle GPU watts, timestamp | Write `3` to `/proc/sys/vm/drop_caches` (requires sudo/root); in mock mode skip drop, return zeroed baseline |
| TELEM-06 | `calculate_headroom()` returns `{safe_threshold, headroom_gb, headroom_pct}` with 5 GB jitter; pin_memory=False; prefetch_factor capped at 4 | Pure arithmetic; confirmed jitter subtraction from MemAvailable before threshold; UMA semantics: pin_memory=False always |
| TELEM-07 | `effective_scale.compute()` applies multiplier tables and returns effective_params, tier dict | Multiplier tables defined in REQUIREMENTS.md; tier thresholds: <=1B→(64,15%), 1-13B→(16,20%), 13-30B→(8,20%), 30B+→(4,25%) |
| TELEM-08 | Correct tier thresholds | Verified in research: four tiers with batch_cap and min_headroom_pct |
| TELEM-09 | AnchorStore: JSON persistence; config_hash = SHA-256 of 9 fields; 7-day expiry | hashlib.sha256; `|`-delimited field concatenation; datetime-based expiry |
| TELEM-10 | Override rules: COMPLETED raises ceiling; OOM/WATCHDOG sets hard cap; HANG logs only, no batch_cap | Verified arithmetic: COMPLETED→max(tier_cap, N+step); OOM→N-step |
| TELEM-11 | `prepare_probe()` writes rollback and probe configs, returns paths dict | Pure file I/O with pathlib; caller runs training steps |
| TELEM-12 | `evaluate_probe()` reads results, compares peak memory to safe_threshold, returns action+reason+anchor_record | Uses calculate_headroom result; returns "commit" or "revert" |
| TELEM-13 | FailureClassifier classifies: clean/oom/hang/thermal/pressure | Logic verified: oom=(gpu<10%+mem<1GB); hang=(gpu<10%+cpu>90%+60s+mem>10GB); thermal=(temp>=85C); pressure=(mem<3GB during training) |
| TELEM-14 | HANG never produces batch_cap field | Confirmed: return dict has no batch_cap key for hang |
| TELEM-15 | pyproject.toml at `dgx-toolbox/telemetry/`; pip install -e; Python 3.10+ and aarch64 safe | nvidia-ml-py is pure Python (py3-none-any wheel); aarch64 safe confirmed |
| TELEM-16 | dgx_toolbox.py `status_report()` adds gpu_telemetry section when pynvml available | Optional import pattern with try/except ImportError; existing status_report() dict in examples/dgx_toolbox.py |
| TELEM-17 | status.sh GPU TELEMETRY block or "sampler not installed" | python3 -c import guard + conditional block in bash |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| nvidia-ml-py | 13.595.45 (pinned `>=13.595,<14`) | NVML Python bindings for GPU metrics | Official NVIDIA release; pure Python wheel; aarch64 safe; exposes `import pynvml` namespace |
| pynvml (NOT to install) | — | Deprecated alternative | Same `import pynvml` namespace as nvidia-ml-py — co-installing causes shadowing; must not be in requirements |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| hashlib | stdlib | SHA-256 for config_hash | Anchor store key derivation |
| json | stdlib | NDJSON append, anchor store persistence | All file I/O |
| pathlib | stdlib | File path handling | All file operations |
| datetime | stdlib | Anchor record timestamps, 7-day expiry | AnchorStore expiry logic |
| pytest | >=8.0 (installed: 9.0.2) | Test framework | Matches harness pattern |
| unittest.mock | stdlib | Mock pynvml for CI | Mock mode testing |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| nvidia-ml-py | pynvml | pynvml is a dead fork; same import name causes shadowing; never use |
| JSON file for anchor store | SQLite | JSON is simpler; anchor store is small (tens of records); no query complexity needed |
| /proc/meminfo direct parse | psutil | psutil adds dependency; /proc/meminfo is authoritative and always present on Linux |

**Installation:**
```bash
# In telemetry/pyproject.toml:
pip install -e dgx-toolbox/telemetry/

# nvidia-ml-py is a dependency declared in telemetry pyproject.toml
# Pin exactly to avoid co-install of legacy pynvml
```

**Version verification (confirmed 2026-04-01):**
```bash
pip index versions nvidia-ml-py
# Latest: 13.595.45 (confirmed)
# Wheel: nvidia_ml_py-13.595.45-py3-none-any.whl (pure Python, aarch64 safe)
```

## Architecture Patterns

### Recommended Project Structure
```
telemetry/
├── pyproject.toml           # package definition, nvidia-ml-py dep
├── telemetry/
│   ├── __init__.py          # empty or version string
│   ├── sampler.py           # GPUSampler class (TELEM-01..04)
│   ├── uma_model.py         # UMAMemModel: sample_baseline, calculate_headroom (TELEM-05..06)
│   ├── effective_scale.py   # EffectiveScale.compute() with multiplier tables (TELEM-07..08)
│   ├── anchor_store.py      # AnchorStore: JSON persistence, override rules (TELEM-09..10)
│   ├── probe.py             # prepare_probe, evaluate_probe (TELEM-11..12)
│   └── failure_classifier.py # classify_failure() (TELEM-13..14)
└── tests/
    ├── __init__.py
    ├── conftest.py           # shared fixtures: mock pynvml, tmp_path
    ├── test_sampler.py       # TELEM-01..04
    ├── test_uma_model.py     # TELEM-05..06
    ├── test_effective_scale.py # TELEM-07..08
    ├── test_anchor_store.py  # TELEM-09..10
    ├── test_probe.py         # TELEM-11..12
    └── test_failure_classifier.py # TELEM-13..14
```

Integration touchpoints (not in telemetry package):
```
dgx-toolbox/
├── examples/dgx_toolbox.py  # status_report() bridge (TELEM-16)
└── status.sh                # GPU TELEMETRY block (TELEM-17)
```

### Pattern 1: Mock-First NVML Init

**What:** GPUSampler tries nvmlInit() at construction time; if it fails (library absent or no GPU), sets `_mock=True` and returns zeroed values from all metric calls.

**When to use:** All NVML calls must be guarded; this pattern enables CI without GPU hardware.

**Example:**
```python
# Source: verified nvidia-ml-py 13.595.45 API + NVML_ERROR_LIBRARY_NOT_FOUND=12
import pynvml

class GPUSampler:
    def __init__(self):
        self._mock = False
        self._handle = None
        try:
            pynvml.nvmlInit()
            self._handle = pynvml.nvmlDeviceGetHandleByIndex(0)
        except pynvml.NVMLError:
            # Covers NVMLError_LibraryNotFound (no .so) and NVMLError_DriverNotLoaded
            self._mock = True

    def sample(self) -> dict:
        if self._mock:
            return self._mock_sample()
        return self._live_sample()

    def _live_sample(self) -> dict:
        watts = pynvml.nvmlDeviceGetPowerUsage(self._handle) / 1000.0
        temp = pynvml.nvmlDeviceGetTemperature(
            self._handle, pynvml.NVML_TEMPERATURE_GPU
        )
        util = pynvml.nvmlDeviceGetUtilizationRates(self._handle).gpu
        mem_avail_gb = self._read_mem_avail()
        cached_gb = self._read_page_cache()
        return {
            "watts": watts,
            "temperature_c": temp,
            "gpu_util_pct": util,
            "mem_available_gb": mem_avail_gb,
            "page_cache_gb": cached_gb,
            "mock": False,
        }
```

### Pattern 2: nvmlDeviceGetMemoryInfo UMA Fallback

**What:** On GB10, nvmlDeviceGetMemoryInfo raises NVMLError_NotSupported (error code 3). Always parse /proc/meminfo MemAvailable instead. Never use MemFree.

**When to use:** Any memory read — primary path on GB10, not an edge case.

**Example:**
```python
# Source: verified — NVML_ERROR_NOT_SUPPORTED=3, MemAvailable vs MemFree gap confirmed on DGX
from pathlib import Path

def _read_mem_avail(self) -> float:
    """Returns MemAvailable in GB. Never uses nvmlDeviceGetMemoryInfo."""
    meminfo = Path("/proc/meminfo").read_text()
    for line in meminfo.splitlines():
        if line.startswith("MemAvailable:"):
            kb = int(line.split()[1])
            return kb / (1024 * 1024)
    return 0.0

def _read_page_cache(self) -> float:
    """Returns Cached (page cache) in GB from /proc/meminfo."""
    meminfo = Path("/proc/meminfo").read_text()
    for line in meminfo.splitlines():
        if line.startswith("Cached:"):
            kb = int(line.split()[1])
            return kb / (1024 * 1024)
    return 0.0
```

Key observation from research: On this DGX Spark, MemAvailable=14.3 GB vs MemFree=6.3 GB — an 8 GB gap under normal load. Using MemFree would signal false OOM conditions constantly.

### Pattern 3: OOM Retry Flag — Outside Except Block

**What:** PyTorch OOM exceptions prevent CUDA memory from being freed inside the `except` block. All retry/recovery logic must use a flag set inside `except` and acted upon after the block ends.

**When to use:** Any training loop wrapper that catches torch.cuda.OutOfMemoryError.

**Example:**
```python
# Source: STATE.md decision — PyTorch OOM reference leak pattern
oom_occurred = False
try:
    run_training_step()
except torch.cuda.OutOfMemoryError:
    oom_occurred = True  # DO NOT retry here — tensors still referenced

# All recovery outside except block
if oom_occurred:
    torch.cuda.empty_cache()
    record_failure(classification="oom")
```

### Pattern 4: Anchor Store Config Hash

**What:** Deterministic SHA-256 of 9 fixed fields concatenated with `|` separator. Field order is fixed forever after first write.

**Example:**
```python
# Source: STATE.md architecture decision — field order locked
import hashlib

HASH_FIELDS = [
    "model_id", "quant_mode", "framework", "grad_ckpt",
    "lora_rank", "seq_len", "optimizer", "batch_size", "grad_accum"
]

def compute_config_hash(config: dict) -> str:
    key_str = "|".join(str(config[f]) for f in HASH_FIELDS)
    return hashlib.sha256(key_str.encode()).hexdigest()
```

### Pattern 5: HANG Never Produces batch_cap

**What:** The HANG classification dict must never contain a `batch_cap` key. Callers should not apply batch backoff when the cause is a dataloader hang, not memory pressure.

**Example:**
```python
# Source: REQUIREMENTS.md TELEM-14 + STATE.md decision
def classify_failure(final_readings, exit_code, training_completed):
    # ... classification logic ...
    if is_hang:
        # NEVER add batch_cap here — callers would wrongly reduce batch size
        return {
            "classification": "hang",
            "evidence": {
                "gpu_util_pct": gpu_util,
                "cpu_pct": cpu_pct,
                "duration_s": duration_at_state,
                "mem_available_gb": mem_avail,
            }
            # No "batch_cap" key — this is intentional and load-bearing
        }
```

### Pattern 6: Conditional Import for dgx_toolbox.py Bridge

**What:** The telemetry package is optional — dgx_toolbox.py must import it only if installed.

**Example:**
```python
# Source: existing harness pattern (Phase 5 decision: importlib.import_module for optional deps)
def status_report(self) -> dict:
    result = { ... existing fields ... }
    try:
        from telemetry.sampler import GPUSampler
        sampler = GPUSampler()
        result["gpu_telemetry"] = sampler.sample()
    except ImportError:
        pass  # telemetry package not installed — omit section
    return result
```

### Pattern 7: status.sh Conditional Block

**What:** Bash guard that checks if the sampler module is importable before calling it.

**Example:**
```bash
# Source: existing status.sh pattern in dgx-toolbox
echo ""
echo "GPU TELEMETRY"
if python3 -c "from telemetry.sampler import GPUSampler" 2>/dev/null; then
    python3 - <<'PYEOF'
from telemetry.sampler import GPUSampler
s = GPUSampler()
d = s.sample()
print(f"  Watts:        {d['watts']:.1f} W")
print(f"  Temperature:  {d['temperature_c']} C")
print(f"  Utilization:  {d['gpu_util_pct']} %")
PYEOF
else
    echo "  sampler not installed"
fi
```

### Anti-Patterns to Avoid

- **Co-installing pynvml:** Both `pynvml` and `nvidia-ml-py` expose `import pynvml`. Installing both causes whichever was installed last to win. Pin `nvidia-ml-py>=13.595,<14` only; never add `pynvml` to requirements.
- **Using MemFree for memory checks:** MemFree excludes page cache. On this DGX, the gap is 8 GB under normal load. MemFree causes false OOM signals.
- **Calling nvmlDeviceGetMemoryInfo on GB10:** This raises NVMLError_NotSupported. Skip it entirely; use /proc/meminfo MemAvailable.
- **Recovery logic inside `except OOM` block:** PyTorch tensors remain referenced until the except block exits. Any retry inside the except block will immediately OOM again.
- **HANG with batch_cap:** A hang is caused by dataloader deadlock or CPU starvation, not memory. Reducing batch size after a hang is incorrect behavior and must be prevented by the absence of the batch_cap field.
- **Storing MemFree in baseline:** sample_baseline() must store MemAvailable (not MemFree) or the headroom calculation will be wrong by 5-10 GB.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| GPU power/temp/util reads | nvidia-smi subprocess | pynvml direct API | subprocess adds latency, parsing brittleness, and subprocess invocation is explicitly forbidden by TELEM-01 |
| NVMLError class hierarchy | Manual integer error code mapping | pynvml.NVMLError dynamic subclasses | Library auto-generates NVMLError_NotSupported, NVMLError_LibraryNotFound etc from error strings |
| Memory reads on UMA | nvmlDeviceGetMemoryInfo | /proc/meminfo MemAvailable | nvmlDeviceGetMemoryInfo raises NVMLError_NotSupported on GB10 |
| SHA-256 hash | Custom fingerprint | hashlib.sha256 | Edge cases in ordering and encoding; stdlib is correct |
| JSON append | Custom file format | json.dumps + file.write('\n') | NDJSON is trivial with stdlib; no schema complexity |

**Key insight:** NVML wraps libnvidia-ml.so.1 C library calls directly without subprocess. This is the only approach that satisfies the "no subprocess invocation" requirement in TELEM-01.

## Common Pitfalls

### Pitfall 1: pynvml vs nvidia-ml-py Namespace Collision
**What goes wrong:** `pip install pynvml` and `pip install nvidia-ml-py` both provide `import pynvml`. Whichever package was installed last wins. The API surface is slightly different — legacy pynvml (13.0.1) has different method signatures and may not have NVMLError subclasses.
**Why it happens:** Historical fork — pynvml was the community maintained fork before NVIDIA published nvidia-ml-py.
**How to avoid:** Only declare `nvidia-ml-py>=13.595,<14` in pyproject.toml dependencies. Add a note in CONTRIBUTING or requirements that pynvml must not be installed. Consider adding a startup assertion: `assert hasattr(pynvml, 'nvmlInit')`.
**Warning signs:** `AttributeError: module 'pynvml' has no attribute 'NVMLError_NotSupported'`

### Pitfall 2: drop_caches Requires Root
**What goes wrong:** `echo 3 > /proc/sys/vm/drop_caches` requires root/sudo. Running `sample_baseline()` as a non-root user will raise PermissionError silently if not handled.
**Why it happens:** drop_caches is a privileged kernel operation.
**How to avoid:** Wrap the drop_caches write in try/except PermissionError; log a warning that baseline may include page cache noise; continue without dropping. The baseline is a best-effort measurement.
**Warning signs:** PermissionError on write; baseline MemAvailable identical to current MemAvailable even when cache is warm.

### Pitfall 3: NVMLError_NotSupported Only on GB10 UMA — Not a Bug
**What goes wrong:** Developer tests on a dGPU (discrete GPU) and nvmlDeviceGetMemoryInfo works fine. Code ships to DGX Spark (GB10 UMA) and crashes.
**Why it happens:** GB10 does not expose separate GPU memory — it is unified with system RAM. NVML returns NOT_SUPPORTED for the memory query.
**How to avoid:** The UMA fallback (/proc/meminfo) must always execute on the live sampling path. Do not make the fallback conditional on catching an exception — always use /proc/meminfo for MemAvailable.
**Warning signs:** Code only breaks on GB10 hardware; works fine in development on non-UMA machines.

### Pitfall 4: Anchor Store Config Hash Field Order Must Never Change
**What goes wrong:** If the HASH_FIELDS list order changes after records have been written, existing records become orphaned (their hash no longer matches incoming configs with identical parameters).
**Why it happens:** dict ordering in Python 3.7+ is stable but JSON keys are unordered — if hash is derived from json.dumps(config) without sorted keys, hash changes between Python versions.
**How to avoid:** Use the fixed HASH_FIELDS list (not json.dumps) for hash derivation. Never reorder the list. The order is locked in STATE.md.
**Warning signs:** Anchor lookups always miss; probe protocol never finds prior history.

### Pitfall 5: HANG Classification Duration Check
**What goes wrong:** A momentary CPU spike (1-2 seconds) triggers a hang classification even though the GPU will resume in seconds.
**Why it happens:** Hang detection requires sustained CPU>90% + GPU idle for 60 seconds. If duration_at_state is not tracked properly, any brief CPU spike flags as a hang.
**How to avoid:** The `duration_at_state_s` field in final_readings must represent how long the CPU>90%+GPU<10% state has been continuous, not the instantaneous snapshot.
**Warning signs:** False hang classifications during normal batch loading (brief CPU spikes between batches).

### Pitfall 6: Mock Mode Must Not Read /proc/meminfo in Frozen Mock
**What goes wrong:** Mock mode that still reads /proc/meminfo will return the host machine's actual memory state in CI. Tests that assert specific memory values will be non-deterministic.
**How to avoid:** Mock mode returns a fully static dict with predetermined values. All memory values in mock are fixed constants (e.g., `{"mem_available_gb": 80.0, "mock": True}`).
**Warning signs:** Tests pass locally but fail in CI due to different actual memory values.

## Code Examples

### GPUSampler Minimal Implementation

```python
# Source: nvidia-ml-py 13.595.45 verified API + /proc/meminfo verified format
import pynvml
from pathlib import Path

class GPUSampler:
    def __init__(self):
        self._mock = False
        self._handle = None
        try:
            pynvml.nvmlInit()
            self._handle = pynvml.nvmlDeviceGetHandleByIndex(0)
        except pynvml.NVMLError:
            self._mock = True

    def sample(self) -> dict:
        if self._mock:
            return {
                "watts": 0.0, "temperature_c": 0,
                "gpu_util_pct": 0, "mem_available_gb": 0.0,
                "page_cache_gb": 0.0, "mock": True,
            }
        watts = pynvml.nvmlDeviceGetPowerUsage(self._handle) / 1000.0
        temp = pynvml.nvmlDeviceGetTemperature(
            self._handle, pynvml.NVML_TEMPERATURE_GPU
        )
        util = pynvml.nvmlDeviceGetUtilizationRates(self._handle).gpu
        return {
            "watts": watts,
            "temperature_c": temp,
            "gpu_util_pct": util,
            "mem_available_gb": self._read_meminfo("MemAvailable"),
            "page_cache_gb": self._read_meminfo("Cached"),
            "mock": False,
        }

    def _read_meminfo(self, key: str) -> float:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith(f"{key}:"):
                return int(line.split()[1]) / (1024 * 1024)
        return 0.0

    def append_jsonl(self, path) -> None:
        import json, time
        record = self.sample()
        record["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with open(path, "a") as f:
            f.write(json.dumps(record) + "\n")
```

### AnchorStore Key and Override Logic

```python
# Source: REQUIREMENTS.md TELEM-09/10 + STATE.md decisions
import hashlib, json
from datetime import datetime, timedelta, timezone
from pathlib import Path

HASH_FIELDS = [
    "model_id", "quant_mode", "framework", "grad_ckpt",
    "lora_rank", "seq_len", "optimizer", "batch_size", "grad_accum"
]

class AnchorStore:
    EXPIRY_DAYS = 7

    def __init__(self, store_path: Path):
        self._path = store_path
        self._records: dict = self._load()

    def compute_config_hash(self, config: dict) -> str:
        key_str = "|".join(str(config[f]) for f in HASH_FIELDS)
        return hashlib.sha256(key_str.encode()).hexdigest()

    def apply_override(self, config_hash: str, status: str, batch_size: int,
                       tier_cap: int, step_size: int = 2) -> dict:
        if status == "COMPLETED":
            new_cap = max(tier_cap, batch_size + step_size)
            record = {"status": status, "batch_cap": new_cap,
                      "created_at": datetime.now(timezone.utc).isoformat()}
        elif status in ("OOM", "WATCHDOG"):
            record = {"status": status, "batch_cap": batch_size - step_size,
                      "created_at": datetime.now(timezone.utc).isoformat()}
        elif status == "HANG":
            # HANG never produces batch_cap — prevents incorrect backoff
            record = {"status": status,
                      "created_at": datetime.now(timezone.utc).isoformat()}
        else:
            raise ValueError(f"Unknown status: {status}")
        self._records[config_hash] = record
        self._save()
        return record

    def _is_expired(self, record: dict) -> bool:
        created = datetime.fromisoformat(record["created_at"])
        return (datetime.now(timezone.utc) - created) > timedelta(days=self.EXPIRY_DAYS)
```

### Failure Classifier

```python
# Source: REQUIREMENTS.md TELEM-13/14
def classify_failure(final_readings: dict, exit_code: int,
                     training_completed: bool) -> dict:
    if training_completed and exit_code == 0:
        return {"classification": "clean", "evidence": {}}

    mem_gb = final_readings.get("mem_available_gb", 99.0)
    gpu_util = final_readings.get("gpu_util_pct", 100)
    cpu_pct = final_readings.get("cpu_pct", 0)
    temp_c = final_readings.get("temperature_c", 0)
    duration_s = final_readings.get("duration_at_state_s", 0)

    # OOM: GPU idle + near-zero memory
    if gpu_util < 10 and mem_gb < 1.0:
        return {"classification": "oom",
                "evidence": {"mem_available_gb": mem_gb, "gpu_util_pct": gpu_util}}

    # HANG: GPU idle + CPU saturated + 60s sustained + memory healthy
    # CRITICAL: no batch_cap in this return (TELEM-14)
    if gpu_util < 10 and cpu_pct > 90 and duration_s >= 60 and mem_gb > 10.0:
        return {"classification": "hang",
                "evidence": {"gpu_util_pct": gpu_util, "cpu_pct": cpu_pct,
                             "duration_s": duration_s, "mem_available_gb": mem_gb}}

    # Thermal: sustained high temperature
    if temp_c >= 85:
        return {"classification": "thermal", "evidence": {"temperature_c": temp_c}}

    # Pressure: low memory but not full OOM
    if mem_gb < 3.0:
        return {"classification": "pressure", "evidence": {"mem_available_gb": mem_gb}}

    return {"classification": "clean", "evidence": {}}
```

### pyproject.toml for Telemetry Package

```toml
# Source: harness/pyproject.toml pattern adapted for telemetry
[build-system]
requires = ["setuptools>=61"]
build-backend = "setuptools.build_meta"

[tool.setuptools.packages.find]
where = [".."]
include = ["telemetry*"]

[project]
name = "dgx-telemetry"
version = "0.1.0"
requires-python = ">=3.10"
dependencies = [
    "nvidia-ml-py>=13.595,<14",
]

[project.optional-dependencies]
test = [
    "pytest>=8.0",
]

[tool.pytest.ini_options]
testpaths = ["tests"]
```

**Critical note:** Do not add `pynvml` to dependencies. Both `pynvml` and `nvidia-ml-py` expose `import pynvml` and co-installation causes shadowing.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `pynvml` community fork | `nvidia-ml-py` official NVIDIA package | ~2020 | Same import name; nvidia-ml-py is actively maintained against latest NVML API |
| `nvidia-smi` subprocess for GPU stats | `pynvml` direct API | Always preferred | No subprocess spawn; structured return types; no stdout parsing |
| MemFree for available memory | MemAvailable | Linux kernel 3.14 | MemAvailable accounts for reclaimable page cache; critical for UMA systems |

**Deprecated/outdated:**
- `pynvml` package: frozen at 13.0.1; no longer maintained; still works but must not co-install with nvidia-ml-py

## Open Questions

1. **nvmlDeviceGetCurrentClocksThrottleReasons bitmask on GB10**
   - What we know: STATE.md flags this as pending — "Verify `nvmlDeviceGetCurrentClocksThrottleReasons` bitmask behavior on GB10 — implement with graceful NVMLError fallback"
   - What's unclear: Whether this call returns NOT_SUPPORTED on GB10 UMA like nvmlDeviceGetMemoryInfo
   - Recommendation: Implement with NVMLError catch; this metric is not required by any TELEM requirement — skip for Phase 13

2. **GB10 dmesg OOM line format for FailureClassifier**
   - What we know: STATE.md blocker — "GB10 dmesg OOM line format not confirmed — FailureClassifier dmesg parser pattern must be configurable"
   - What's unclear: Whether FailureClassifier needs to parse dmesg or whether the current approach (exit_code + final_readings snapshot) is sufficient
   - Recommendation: Phase 13 classifier uses exit_code and telemetry snapshot only (no dmesg parsing) — the dmesg pattern concern is for future enhancement

3. **drop_caches permissions in training containers**
   - What we know: /proc/sys/vm/drop_caches exists but requires root; verified on this machine
   - What's unclear: Whether training containers run with sufficient privileges to write drop_caches
   - Recommendation: Wrap in try/except PermissionError; log warning; proceed without cache drop; baseline is still valid (just may include cached pages)

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Python 3.10+ | Package requirement | Yes | 3.13.12 | — |
| aarch64 platform | Package aarch64 safety | Yes | Linux aarch64 | — |
| nvidia-ml-py 13.595.45 | GPUSampler NVML calls | Not installed (needs pip install) | — | Mock mode (auto-activated when libnvidia-ml.so.1 absent) |
| libnvidia-ml.so.1 | NVML runtime | Not confirmed available on CI | — | Mock mode — all tests pass without it |
| /proc/meminfo | UMA memory reads | Yes | present | — |
| /proc/sys/vm/drop_caches | sample_baseline() cache flush | Yes (file exists) | — | PermissionError fallback — non-root skips flush, logs warning |
| pytest 9.0.2 | Test suite | Yes | 9.0.2 | — |

**Missing dependencies with no fallback:**
- None — all blocking dependencies have either fallbacks or are pure Python (installable).

**Missing dependencies with fallback:**
- nvidia-ml-py: not yet installed on this environment; goes into pyproject.toml as a declared dependency; mock mode handles CI runs where libnvidia-ml.so.1 is absent.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | pytest 9.0.2 |
| Config file | `telemetry/pyproject.toml` [tool.pytest.ini_options] |
| Quick run command | `cd dgx-toolbox/telemetry && pytest tests/ -x -q` |
| Full suite command | `cd dgx-toolbox/telemetry && pytest tests/ -v` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| TELEM-01 | GPUSampler.sample() returns complete dict with all fields | unit | `pytest tests/test_sampler.py::test_sample_returns_all_fields -x` | Wave 0 |
| TELEM-02 | /proc/meminfo fallback when nvmlDeviceGetMemoryInfo unavailable | unit | `pytest tests/test_sampler.py::test_uma_memory_fallback -x` | Wave 0 |
| TELEM-03 | append_jsonl writes valid NDJSON | unit | `pytest tests/test_sampler.py::test_append_jsonl -x` | Wave 0 |
| TELEM-04 | Mock mode: no crash when NVML library absent | unit | `pytest tests/test_sampler.py::test_mock_mode_no_gpu -x` | Wave 0 |
| TELEM-05 | sample_baseline() returns baseline dict; handles PermissionError on drop_caches | unit | `pytest tests/test_uma_model.py::test_sample_baseline -x` | Wave 0 |
| TELEM-06 | calculate_headroom() with 5 GB jitter; safe_threshold correct | unit | `pytest tests/test_uma_model.py::test_calculate_headroom -x` | Wave 0 |
| TELEM-07 | effective_scale.compute() returns effective_params and tier dict | unit | `pytest tests/test_effective_scale.py::test_compute_returns_tier -x` | Wave 0 |
| TELEM-08 | Correct tier thresholds for all four tiers | unit | `pytest tests/test_effective_scale.py::test_tier_thresholds -x` | Wave 0 |
| TELEM-09 | AnchorStore: write, read, expiry | unit | `pytest tests/test_anchor_store.py::test_write_read_expire -x` | Wave 0 |
| TELEM-10 | COMPLETED raises ceiling; OOM/WATCHDOG sets cap; HANG no batch_cap | unit | `pytest tests/test_anchor_store.py::test_override_rules -x` | Wave 0 |
| TELEM-11 | prepare_probe() writes rollback and probe configs | unit | `pytest tests/test_probe.py::test_prepare_probe -x` | Wave 0 |
| TELEM-12 | evaluate_probe() returns commit/revert with anchor_record | unit | `pytest tests/test_probe.py::test_evaluate_probe -x` | Wave 0 |
| TELEM-13 | classify_failure() classifies all 5 outcomes | unit | `pytest tests/test_failure_classifier.py::test_classify_all_outcomes -x` | Wave 0 |
| TELEM-14 | HANG classification never contains batch_cap field | unit | `pytest tests/test_failure_classifier.py::test_hang_no_batch_cap -x` | Wave 0 |
| TELEM-15 | Package installable via pip install -e | smoke | `pip install -e dgx-toolbox/telemetry/ && python -c "from telemetry.sampler import GPUSampler"` | Wave 0 |
| TELEM-16 | status_report() includes/omits gpu_telemetry based on availability | unit | `pytest tests/test_dgx_toolbox_bridge.py -x` | Wave 0 |
| TELEM-17 | status.sh GPU TELEMETRY block or "sampler not installed" | smoke | manual run of `bash status.sh` or shell test | Wave 0 |

### Sampling Rate
- **Per task commit:** `cd dgx-toolbox/telemetry && pytest tests/ -x -q`
- **Per wave merge:** `cd dgx-toolbox/telemetry && pytest tests/ -v`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `telemetry/tests/conftest.py` — shared fixtures: mock pynvml module, tmp_path anchor store
- [ ] `telemetry/tests/test_sampler.py` — covers TELEM-01..04
- [ ] `telemetry/tests/test_uma_model.py` — covers TELEM-05..06
- [ ] `telemetry/tests/test_effective_scale.py` — covers TELEM-07..08
- [ ] `telemetry/tests/test_anchor_store.py` — covers TELEM-09..10
- [ ] `telemetry/tests/test_probe.py` — covers TELEM-11..12
- [ ] `telemetry/tests/test_failure_classifier.py` — covers TELEM-13..14
- [ ] `telemetry/tests/test_dgx_toolbox_bridge.py` — covers TELEM-16
- [ ] `telemetry/pyproject.toml` — package definition; test infrastructure install

**Key fixture needed in conftest.py:**
```python
# Mock pynvml module for all tests — enables CI without GPU
from unittest.mock import MagicMock, patch
import sys

@pytest.fixture(autouse=False)
def mock_pynvml():
    """Patch pynvml so GPUSampler enters mock mode."""
    mock_mod = MagicMock()
    mock_mod.nvmlInit.side_effect = Exception("No GPU in CI")
    with patch.dict(sys.modules, {"pynvml": mock_mod}):
        yield mock_mod
```

## Sources

### Primary (HIGH confidence)
- `nvidia_ml_py-13.595.45-py3-none-any.whl` (downloaded from PyPI 2026-04-01) — complete pynvml.py API surface, error constants, NVMLError class generation, _LoadNvmlLibrary behavior when .so absent
- `/proc/meminfo` live read on DGX Spark — confirmed MemAvailable vs MemFree gap of 8.1 GB under normal load; confirmed Cached field for page cache
- `/proc/sys/vm/drop_caches` — confirmed file exists; requires root to write
- `examples/dgx_toolbox.py` (live code) — existing status_report() structure; existing /proc/meminfo parse pattern
- `harness/pyproject.toml` (live code) — Python package structure pattern for this repo
- `.planning/STATE.md` v1.3 Architecture Decisions — all locked decisions researched directly

### Secondary (MEDIUM confidence)
- PyPI version history for nvidia-ml-py — confirmed 13.595.45 is latest (2026-04-01)
- PyPI version history for pynvml — confirmed 13.0.1 is latest; inactive
- GitHub codecarbon issue #1037 — confirms NVMLError_NotSupported on Blackwell/GB10 for memory queries

### Tertiary (LOW confidence)
- WebSearch results on GB10 UMA nvmlDeviceGetMemoryInfo behavior — consistent with STATE.md decision but not verified against official NVIDIA documentation for GB10 specifically

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — nvidia-ml-py downloaded and API surface fully inspected; versions verified on PyPI
- Architecture: HIGH — locked decisions from STATE.md; /proc/meminfo format verified live; pynvml API verified from source
- Pitfalls: HIGH — pynvml/nvidia-ml-py collision verified; drop_caches permissions verified live; MemAvailable vs MemFree gap measured live (8.1 GB)

**Research date:** 2026-04-01
**Valid until:** 2026-05-01 (nvidia-ml-py stable; /proc/meminfo format stable)
