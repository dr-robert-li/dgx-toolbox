# Architecture Research

**Domain:** GPU telemetry primitives — DGX Spark GB10 UMA integration
**Researched:** 2026-04-01
**Confidence:** HIGH (pynvml/nvidia-ml-py official docs + NVIDIA UMA guidance + existing codebase analysis)

## Standard Architecture

### System Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Consumer Layer (callers)                          │
│  ┌──────────────┐  ┌────────────────────┐  ┌──────────────────────┐ │
│  │  status.sh   │  │  dgx_toolbox.py    │  │  Unsloth / training  │ │
│  │  (bash block)│  │  (programmatic)    │  │  containers          │ │
│  └──────┬───────┘  └────────┬───────────┘  └──────────┬───────────┘ │
│         │                   │                          │             │
├─────────┴───────────────────┴──────────────────────────┴─────────────┤
│                  telemetry/ Python package                            │
│  ┌────────────┐ ┌──────────────┐ ┌─────────────┐ ┌────────────────┐ │
│  │ GPUSampler │ │  UMAMemModel │ │ ScaleFormula│ │  AnchorStore   │ │
│  │(sampler.py)│ │  (uma.py)    │ │ (scale.py)  │ │  (anchors.py)  │ │
│  └──────┬─────┘ └──────┬───────┘ └──────┬──────┘ └───────┬────────┘ │
│         │              │                │                 │          │
│  ┌──────┴──────────────┴────────────────┴─────────────────┴────────┐ │
│  │              ProbeProtocol (probe.py)                            │ │
│  │              FailureClassifier (classifier.py)                   │ │
│  └──────────────────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────────────────┤
│                      Hardware / OS Layer                             │
│  ┌──────────────────────┐  ┌──────────────────────────────────────┐ │
│  │  nvidia-ml-py (NVML) │  │  /proc/meminfo  (UMA memory source)  │ │
│  │  GPU util, temp,     │  │  MemAvailable, SwapFree, SwapTotal   │ │
│  │  sm_clock, power     │  │  (accurate unified pool view)        │ │
│  └──────────────────────┘  └──────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Responsibility | Lives In |
|-----------|----------------|----------|
| `GPUSampler` | Single-sample snapshot of GPU util, temp, clocks, power via NVML; explicitly does NOT call NVML memory queries on UMA | `telemetry/sampler.py` |
| `UMAMemModel` | Derives true available headroom from /proc/meminfo accounting for buffer cache, swap pressure, and jitter margin | `telemetry/uma.py` |
| `ScaleFormula` | Translates raw memory headroom into an effective batch-size multiplier using empirical tier tables | `telemetry/scale.py` |
| `AnchorStore` | JSON-persisted record of validated batch configs keyed by (model_id, dtype, seq_len); applies OOM/COMPLETED/HANG/WATCHDOG override rules | `telemetry/anchors.py` |
| `ProbeProtocol` | Stateful prepare/evaluate cycle that runs a candidate batch config and records the outcome via `FailureClassifier` | `telemetry/probe.py` |
| `FailureClassifier` | Classifies subprocess/exception exit signals into clean/oom/hang/thermal/pressure enum | `telemetry/classifier.py` |
| `dgx_toolbox.py` bridge | Thin shim adding telemetry checks to the existing `DGXToolbox` validation engine; exposes `get_gpu_snapshot()` and `get_mem_headroom()` | `examples/dgx_toolbox.py` (modified) |
| `status.sh` GPU block | Bash calls `python3 -c "from telemetry import ..."` to embed GPU state in the service status dashboard | `status.sh` (modified) |

## Recommended Project Structure

```
dgx-toolbox/
├── telemetry/                  # NEW: GPU telemetry Python package
│   ├── __init__.py             # Public API re-exports
│   ├── sampler.py              # GPUSampler — NVML (util/temp/clocks/power only)
│   ├── uma.py                  # UMAMemModel — /proc/meminfo headroom + jitter
│   ├── scale.py                # ScaleFormula — batch multiplier tiers
│   ├── anchors.py              # AnchorStore — JSON persistence + override rules
│   ├── probe.py                # ProbeProtocol — prepare/evaluate cycle
│   ├── classifier.py           # FailureClassifier — exit signal enum
│   ├── tests/
│   │   ├── __init__.py
│   │   ├── conftest.py
│   │   ├── test_sampler.py
│   │   ├── test_uma.py
│   │   ├── test_scale.py
│   │   ├── test_anchors.py
│   │   ├── test_probe.py
│   │   └── test_classifier.py
│   └── data/
│       └── .gitkeep            # anchors.json written here at runtime (gitignored)
├── examples/
│   └── dgx_toolbox.py          # MODIFIED: adds telemetry bridge
├── status.sh                   # MODIFIED: adds GPU telemetry block
└── harness/                    # UNCHANGED
```

### Structure Rationale

- **`telemetry/` at repo root, not inside `harness/`:** The safety harness is an LLM safety gateway. Telemetry must be importable by `examples/dgx_toolbox.py`, `status.sh`, and any training container — without requiring the harness to be running. Placing it at the top level prevents a circular or inappropriate dependency on `harness/`.
- **`telemetry/data/`:** Anchor store JSON lives here on the host filesystem. The directory is committed (via `.gitkeep`); `anchors.json` itself is gitignored to prevent test-anchor pollution from landing in main.
- **`harness/` untouched:** The safety harness has no GPU-aware logic and should stay that way. Telemetry is a separate concern from request safety.
- **`examples/dgx_toolbox.py` modified, not replaced:** The existing `DGXToolbox` class has a named validation engine (`gpu`, `memory` checks). The bridge adds `telemetry` checks to that engine without restructuring it.

## Architectural Patterns

### Pattern 1: Dual-Source Memory Sampling (UMA-Safe)

**What:** Always read GPU compute metrics (utilization, temperature, clocks, power) from NVML; always read memory availability from `/proc/meminfo` — never from `cudaMemGetInfo` or `nvmlDeviceGetMemoryInfo` on GB10.

**When to use:** Any memory headroom calculation on DGX Spark. NVML memory APIs return physically free framebuffer pages and undercount by excluding reclaimable buffer cache, causing phantom OOM projections in the probe protocol.

**Trade-offs:** `/proc/meminfo` is a syscall read (negligible overhead, < 1ms). The downside is that `MemAvailable` includes reclaim candidates — the `UMAMemModel` must apply a jitter margin (recommended 12% of 128 GB total pool) to account for the OS not reclaiming synchronously under GPU load.

**Example:**
```python
# sampler.py — correct dual-source pattern
import pynvml   # package: nvidia-ml-py; import name is still pynvml

class GPUSampler:
    def __init__(self, device_index: int = 0):
        pynvml.nvmlInit()
        self._handle = pynvml.nvmlDeviceGetHandleByIndex(device_index)

    def sample(self) -> dict:
        util = pynvml.nvmlDeviceGetUtilizationRates(self._handle)
        temp = pynvml.nvmlDeviceGetTemperature(
            self._handle, pynvml.NVML_TEMPERATURE_GPU
        )
        # Do NOT call nvmlDeviceGetMemoryInfo on GB10 — it reports
        # framebuffer pages only, not the unified 128GB pool.
        # Memory headroom comes from UMAMemModel (/proc/meminfo).
        return {
            "gpu_util_pct": util.gpu,
            "mem_util_pct": util.memory,
            "temp_c": temp,
        }

    def __del__(self):
        try:
            pynvml.nvmlShutdown()
        except Exception:
            pass
```

### Pattern 2: /proc/meminfo Headroom Model with Jitter Margin

**What:** Parse `MemAvailable` from `/proc/meminfo` to derive a conservative usable headroom figure. Do not count swap toward GPU-safe headroom.

**When to use:** Before any batch size decision, before probe evaluation, and in the AnchorStore headroom staleness check.

**Trade-offs:** `MemAvailable` slightly over-counts (assumes Linux page reclaim succeeds synchronously). The jitter margin compensates. Swap must not be counted toward GPU-safe headroom because swapping during GPU kernel execution causes hangs on UMA systems — CUDA does not tolerate swap pressure mid-kernel.

**Example:**
```python
# uma.py
from dataclasses import dataclass
from pathlib import Path

JITTER_FRACTION = 0.12   # 12% of total pool reserved for OS jitter

@dataclass
class MemSnapshot:
    total_bytes: int
    available_bytes: int      # raw MemAvailable from /proc/meminfo
    headroom_bytes: int       # available_bytes minus jitter margin
    swap_free_bytes: int      # informational only — not added to headroom

class UMAMemModel:
    TOTAL_BYTES = 128 * 1024 ** 3   # GB10: fixed 128 GB pool

    def snapshot(self) -> MemSnapshot:
        info = {}
        for line in Path("/proc/meminfo").read_text().splitlines():
            k, v = line.split(":", 1)
            info[k.strip()] = int(v.strip().split()[0]) * 1024  # kB -> bytes
        available = info["MemAvailable"]
        jitter = int(self.TOTAL_BYTES * JITTER_FRACTION)
        headroom = max(0, available - jitter)
        return MemSnapshot(
            total_bytes=self.TOTAL_BYTES,
            available_bytes=available,
            headroom_bytes=headroom,
            swap_free_bytes=info.get("SwapFree", 0),
        )
```

### Pattern 3: Anchor Store with Override Rules

**What:** A single JSON file keyed by `(model_id, dtype, seq_len)` storing the last validated batch size and the outcome that produced it. Override rules apply before any probe is attempted.

**When to use:** The probe protocol checks the anchor store first. If a valid anchor exists and current headroom has not shrunk more than 15% from the headroom at anchor time, the anchor is trusted directly and no probe is run.

**Trade-offs:** JSON is sufficient — anchor sets are small (tens of entries per host). SQLite would add another DB alongside `harness/data/traces.db` with no query benefit. The override rules are simple state-machine logic, not relational queries. Atomic write (temp file + rename) handles concurrent access from multiple processes.

**Example:**
```python
# anchors.py — key schema and override rules
from dataclasses import dataclass
from typing import Literal

OutcomeT = Literal["COMPLETED", "OOM", "HANG", "WATCHDOG"]

@dataclass
class AnchorEntry:
    batch_size: int
    outcome: OutcomeT
    headroom_bytes_at_anchor: int
    recorded_at: str   # ISO 8601

# Override rules: given a prior outcome, what batch size is safe to try?
OVERRIDE_RULES: dict[OutcomeT, callable] = {
    "OOM":       lambda bs: bs // 2,
    "HANG":      lambda bs: bs // 2,
    "WATCHDOG":  lambda bs: bs // 2,
    "COMPLETED": lambda bs: bs,   # anchor is trusted as-is
}
```

## Data Flow

### Probe Protocol Flow

```
Training caller requests batch config for (model_id, dtype, seq_len)
         |
         v
AnchorStore.get(model_id, dtype, seq_len)
         |
    Anchor found?
   /             \
 YES              NO
  |                |
  v                v
HeadroomStaleness  UMAMemModel.snapshot() -> headroom_bytes
Check              ScaleFormula.recommend(headroom_bytes) -> candidate_bs
  |                |
 OK?               v
  |          ProbeProtocol.prepare(candidate_bs)
  v                |
return anchor      v
                run N trial steps (subprocess)
                GPUSampler.sample() at step boundaries
                   |
                   v
             FailureClassifier.classify(exit_code, stderr, wall_time)
                   |
                   v
             AnchorStore.record(model_id, dtype, seq_len, outcome)
                   |
                   v
             return (batch_size, outcome)
```

### status.sh GPU Telemetry Block Flow

```
User runs: ./status.sh
    |
    v
[existing service rows: vLLM, LiteLLM, Ollama, Harness, ...]
    |
    v
python3 inline call:
  from telemetry import GPUSampler, UMAMemModel
  s = GPUSampler().sample()
  m = UMAMemModel().snapshot()
  print(f"GPU {s['gpu_util_pct']}% util | {s['temp_c']}C | "
        f"{m.headroom_bytes // 1024**3}GB headroom")
    |
    v
Printed as GPU status row in terminal dashboard
```

### Key Data Flows

1. **Baseline sampling (idle path):** `GPUSampler.sample()` and `UMAMemModel.snapshot()` are called on demand — no background thread. Callers drive the sampling frequency. This avoids resource contention with training jobs that own the GPU.

2. **Anchor persistence:** `AnchorStore` reads and writes `telemetry/data/anchors.json` atomically (write-to-tempfile + `os.replace`). The file is host-local, not container-local, and persists across container restarts because the repo root is mounted as a volume in all training containers.

3. **Failure classification:** `FailureClassifier` receives the exit code, stderr snippet, and wall-clock duration of a completed or failed training subprocess. It does not re-sample GPU state after failure (the GPU may be in an error state); it classifies from exit signals captured before the subprocess terminated.

## Integration Points

### New Components (to be created)

| Component | Location | Notes |
|-----------|----------|-------|
| `telemetry/` package | `dgx-toolbox/telemetry/` | New top-level Python package; 6 modules |
| `telemetry/__init__.py` | Public re-exports | Exposes `GPUSampler`, `UMAMemModel`, `ScaleFormula`, `AnchorStore`, `ProbeProtocol`, `FailureClassifier` |
| `telemetry/sampler.py` | `GPUSampler` | NVML util/temp/clocks/power; no memory queries |
| `telemetry/uma.py` | `UMAMemModel` | /proc/meminfo headroom + jitter margin |
| `telemetry/scale.py` | `ScaleFormula` | Batch multiplier tier table |
| `telemetry/anchors.py` | `AnchorStore` | JSON persistence + override rules |
| `telemetry/probe.py` | `ProbeProtocol` | Prepare/evaluate orchestration |
| `telemetry/classifier.py` | `FailureClassifier` | Exit signal -> outcome enum |
| `telemetry/tests/` | 6 test files | Mirror `harness/tests/` pytest structure |
| `telemetry/data/.gitkeep` | Runtime data dir | `anchors.json` written here; gitignored |

### Modified Components (existing, targeted changes)

| Component | Location | Change |
|-----------|----------|--------|
| `examples/dgx_toolbox.py` | `examples/` | Add `telemetry` validation check to `DGXToolbox` validation engine; add `get_gpu_snapshot()` and `get_mem_headroom()` convenience methods |
| `status.sh` | repo root | Add GPU telemetry block after existing service rows — inline Python call into `telemetry`; no bash reimplementation of NVML |
| `.github/workflows/test.yml` | `.github/workflows/` | Add `pytest telemetry/tests/` step alongside existing `harness/tests/` |
| `.gitignore` | repo root | Add `telemetry/data/anchors.json` |

### Unchanged Components

| Component | Reason |
|-----------|--------|
| `harness/` (all modules) | Safety harness has no GPU-aware logic; telemetry is a separate domain |
| `harness/data/traces.db` | Telemetry uses its own JSON store, not the harness SQLite |
| `lib.sh` | No GPU telemetry logic belongs in the shared bash library |
| `modelstore/` | Model storage is a filesystem concern, not a GPU concern |
| `karpathy-autoresearch/spark-config.sh` | Autoresearch does its own GPU config; telemetry primitives are available to it but not mandated |
| `inference/`, `data/`, `eval/` | No changes required |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| `telemetry` <-> `examples/dgx_toolbox.py` | Direct Python import | `dgx_toolbox.py` imports from `telemetry`; no subprocess or HTTP |
| `telemetry` <-> `status.sh` | Inline `python3 -c` one-shot | Bash calls Python once per status invocation; no persistent process |
| `telemetry` <-> training containers | Volume mount of repo root | Container sees `telemetry/` as a local package if repo root is mounted (existing pattern for Unsloth containers) |
| `telemetry` <-> `harness/` | None | Intentionally decoupled |
| `AnchorStore` <-> filesystem | Atomic JSON write | Host-persistent across container restarts |

## Anti-Patterns

### Anti-Pattern 1: Using NVML Memory Queries for Headroom on GB10

**What people do:** Call `pynvml.nvmlDeviceGetMemoryInfo(handle).free` and treat that as available GPU memory.

**Why it's wrong:** On GB10 UMA, NVML reports physical framebuffer pages excluding reclaimable buffer cache. The reported "free" figure can be 30-50 GB lower than what CUDA can actually allocate after a `drop_caches`. Probing against this figure produces batch sizes that are too conservative. NVIDIA's own support document explicitly warns about this.

**Do this instead:** Read `MemAvailable` from `/proc/meminfo` and apply the jitter margin in `UMAMemModel`. Use NVML only for utilization, temperature, clocks, and power — metrics that are accurate on UMA.

### Anti-Pattern 2: Spawning a Background Sampler Thread

**What people do:** Start a daemon thread that calls `GPUSampler.sample()` every N seconds and stores results in a queue.

**Why it's wrong:** Training jobs own the GPU exclusively on the DGX Spark's single-GPU topology. A background sampler alive during training adds NVML overhead and can trigger `NVML_ERROR_GPU_IS_LOST` on recovery from OOM events. There is no safe "background" GPU slot on a single-device system.

**Do this instead:** Sample on-demand, called explicitly at probe checkpoints and at `status.sh` invocation. The sampler is stateless and cheap; it does not need to run continuously.

### Anti-Pattern 3: Persisting Anchors Inside a Container

**What people do:** Write `anchors.json` to a path inside the training container's filesystem (e.g., `/workspace/anchors.json`).

**Why it's wrong:** Container restarts discard the anchor state. Every new training session must reprobe from scratch, defeating the purpose of the anchor store — which exists precisely to avoid repeated probes for the same model/dtype/seq_len combination.

**Do this instead:** Write to `telemetry/data/anchors.json` in the repo root on the host filesystem. If running inside a container, mount the repo root as a volume (already the existing pattern for all training containers in this repo).

### Anti-Pattern 4: Importing from the Deprecated `pynvml` Package

**What people do:** `pip install pynvml` and `import pynvml`.

**Why it's wrong:** The `pynvml` PyPI package is deprecated as of late 2025. NVIDIA's official package is `nvidia-ml-py`, which ships inside all NGC containers (`nvcr.io/nvidia/pytorch:25.09+`) and is actively maintained. The deprecated `pynvml` package emits a `FutureWarning` and may not receive security or compatibility patches.

**Do this instead:** Declare `nvidia-ml-py` in the package dependency. The import statement `import pynvml` is unchanged — only the pip package name differs.

### Anti-Pattern 5: Coupling Telemetry to the Safety Harness

**What people do:** Add GPU sampling endpoints to `harness/main.py` or store GPU telemetry in `harness/data/traces.db`.

**Why it's wrong:** Training pipelines and CLI tools that need GPU telemetry do not and should not require the harness to be running. The harness is optional (can be bypassed). Coupling telemetry to it would break `status.sh` and `dgx_toolbox.py` whenever the harness is stopped.

**Do this instead:** Keep `telemetry/` as a standalone package importable by anyone — the harness, `dgx_toolbox.py`, `status.sh`, or a training script — without any one of them being a prerequisite.

## Suggested Build Order

The feature set has strict dependency ordering. Build in this sequence:

| Order | Component | Depends On | Reason |
|-------|-----------|------------|--------|
| 1 | `telemetry/classifier.py` | Nothing | Pure Python; no hardware calls; defines outcome enum needed by all downstream components |
| 2 | `telemetry/sampler.py` | `nvidia-ml-py` installed | Foundational hardware read; all other components reference its output field schema |
| 3 | `telemetry/uma.py` | `/proc/meminfo` (always present) | Memory headroom model; needed by scale formula and probe protocol |
| 4 | `telemetry/scale.py` | `UMAMemModel` | Translates headroom to batch tier; needs UMA numbers to calibrate tier thresholds |
| 5 | `telemetry/anchors.py` | `FailureClassifier` (outcome enum) | Persistence layer; needs outcome types from step 1 |
| 6 | `telemetry/probe.py` | All above (steps 1-5) | Top-level orchestration; wires all primitives together |
| 7 | `status.sh` GPU block | `GPUSampler`, `UMAMemModel` (steps 2-3) | Minimal surface; can be done as soon as sampling primitives exist |
| 8 | `examples/dgx_toolbox.py` bridge | Full `telemetry/` package (step 6) | Bridge wraps the complete public API; build last to validate API surface |

## Scaling Considerations

This telemetry layer targets a single DGX Spark node. The relevant operational considerations are:

| Scenario | Approach |
|----------|----------|
| Multiple simultaneous callers of `GPUSampler` | NVML is thread-safe; no locking needed in `GPUSampler` |
| Concurrent writes to `AnchorStore` | Atomic rename (`os.replace`) handles concurrent access safely |
| Anchor store growing unbounded | Cap at 200 entries; LRU eviction if limit exceeded (model_id cardinality is bounded in practice) |
| `NVML_ERROR_NOT_SUPPORTED` on some GB10 memory queries | Documented expected behavior; `GPUSampler` catches `pynvml.NVMLError` and returns `None` for that field; callers must handle `None` |
| `status.sh` called during active training | Inline python3 call is read-only and brief (< 50ms); NVML compute metric reads during active training are safe |

## Sources

- [NVML Support for DGX Spark Grace Blackwell Unified Memory — NVIDIA Developer Forums](https://forums.developer.nvidia.com/t/nvml-support-for-dgx-spark-grace-blackwell-unified-memory-community-solution/358869) — MEDIUM confidence (community solution thread; consistent with official NVIDIA UMA docs)
- [Unexpected Available Memory Reporting on DGX Spark — NVIDIA Support](https://nvidia.custhelp.com/app/answers/detail/a_id/5728/~/unexpected-available-memory-reporting-on-dgx-spark) — HIGH confidence (official NVIDIA support guidance)
- [Unified Memory Architecture — NVIDIA/dgx-spark-playbooks DeepWiki](https://deepwiki.com/NVIDIA/dgx-spark-playbooks/9.1-unified-memory-architecture) — MEDIUM confidence (community wiki derived from official NVIDIA playbooks)
- [DGX Spark User Guide — NVIDIA, Mar 2026](https://docs.nvidia.com/dgx/dgx-spark/dgx-spark.pdf) — HIGH confidence (official documentation)
- [nvidia-ml-py — PyPI (NVIDIA official)](https://pypi.org/project/nvidia-ml-py/) — HIGH confidence (official NVIDIA package; replacement for deprecated pynvml)
- [How to Monitor GPU Utilization with OpenTelemetry — OneUptime, Feb 2026](https://oneuptime.com/blog/post/2026-02-06-monitor-gpu-utilization-ml-workloads-opentelemetry/view) — MEDIUM confidence (community pattern, recently published)
- Existing codebase: `/home/robert_li/dgx-toolbox/.planning/codebase/ARCHITECTURE.md` and `STRUCTURE.md` — HIGH confidence (current codebase state, 2026-04-01)

---
*Architecture research for: GPU telemetry primitives — DGX Spark v1.3 milestone*
*Researched: 2026-04-01*
