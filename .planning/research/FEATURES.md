# Feature Research

**Domain:** GPU telemetry primitives — hardware sampling, UMA memory modeling, effective scale computation, anchor stores, probe protocols, and failure classification for DGX Spark (Grace Blackwell, aarch64, unified memory)
**Researched:** 2026-04-01
**Confidence:** HIGH for GPU sampling and UMA fallback (NVIDIA official docs + community forum confirms behavior); MEDIUM for effective scale formula (multiple credible sources, no single canonical implementation); MEDIUM for anchor store / probe protocol (derived from training literature patterns; no off-the-shelf library)

---

> **Milestone context:** This is v1.3 of the DGX Toolbox. v1.0 (tiered storage), v1.1 (safety harness), and v1.2 (autoresearch pipeline) are already built.
> GPU telemetry primitives are a new Python component: `dgx_toolbox.telemetry`. Goal is project-agnostic hardware primitives so downstream training scripts never implement raw hardware calls themselves.
> Dependencies on existing work: `dgx_toolbox.py` bridge (package integration), `status.sh` (GPU telemetry block).

---

## Critical Platform Note: DGX Spark UMA

**HIGH confidence.** `nvmlDeviceGetMemoryInfo` returns `NVML_ERROR_NOT_SUPPORTED` on the DGX Spark GB10 — the integrated GPU has no dedicated framebuffer. Standard NVML memory queries fail entirely. This is a known issue documented by NVIDIA.

The correct approach (confirmed by NVIDIA docs + developer forum community solution):
- Use `/proc/meminfo` fields: `MemAvailable` + `SwapFree` for available memory; `MemTotal` for total
- `cudaMemGetInfo` may work for CUDA allocator view but underestimates available memory (does not account for reclaimable OS page cache)
- Do NOT use `nvmlDeviceGetMemoryInfo` for total/free memory on this hardware — it will fail or return garbage

All other NVML queries (temperature, utilization, power, clock) are supported normally on DGX Spark.

---

## Feature Landscape

### Table Stakes (Users Expect These)

Features any GPU telemetry library must provide. Missing these = callers must implement their own hardware calls, defeating the purpose of the library.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| GPU utilization sampling (%) | Every training loop needs to know if the GPU is being used; baseline for diagnosing hangs vs compute-bound vs memory-bound | LOW | `nvmlDeviceGetUtilizationRates(handle).gpu` — returns 0–100. Sampling period is 1/6s–1s depending on GPU model. Poll at 1s intervals. |
| Memory usage sampling (used / total / free) | OOM prevention requires knowing memory headroom before changing batch size | MEDIUM | **Platform-specific:** On DGX Spark, `nvmlDeviceGetMemoryInfo` fails. Use `/proc/meminfo` (`MemAvailable`, `MemTotal`, `SwapFree`) as canonical source. On discrete GPUs, use `nvmlDeviceGetMemoryInfo`. Implement both paths with automatic detection. |
| Temperature sampling (°C) | Thermal throttling silently degrades training throughput; callers need to know if throttling is active | LOW | `nvmlDeviceGetTemperature(handle, NVML_TEMPERATURE_GPU)`. Throttling starts at ~83°C on H100/B200-class hardware; safe threshold is below 75°C. |
| Power draw sampling (W) | Power cap throttling is a separate throttle path from thermal; needed for failure classification | LOW | `nvmlDeviceGetPowerUsage(handle)` — returns milliwatts; divide by 1000. |
| Clock speed sampling (MHz) | Clock drops are the observable symptom of thermal and power throttle events | LOW | `nvmlDeviceGetClockInfo(handle, NVML_CLOCK_SM)` for compute clock. Compare against `nvmlDeviceGetMaxClockInfo` to detect throttling. |
| Throttle reason flags | Distinguishes thermal throttle from power cap from software from idle — needed for failure classifier | LOW | `nvmlDeviceGetCurrentClocksThrottleReasons(handle)` — returns a bitmask. Covers: HW thermal, HW power brake, SW power cap, SW thermal, sync boost, idle, app clock setting. |
| No-subprocess constraint | All hardware queries must use NVML/Python API directly — no `subprocess.run(['nvidia-smi', ...])` | LOW | Subprocess adds 50–200ms latency per call, not suitable for tight sampling loops. pynvml gives direct NVML access with ~0.1ms per call. |
| pynvml initialization guard | NVML init can fail (no driver, incompatible GPU, permission issues) — must not crash the caller | LOW | Wrap `nvmlInit()` in try/except `NVMLError`. Store init state. All subsequent calls check state before querying. Provide a `.is_available()` method. |
| Clean shutdown / context manager | Resource leak from open NVML handles causes driver warnings; training scripts run many iterations | LOW | Implement `__enter__`/`__exit__`. Call `nvmlShutdown()` on exit. Support both context manager and explicit `.close()`. |
| Single sample vs continuous sampling | Training scripts want both: one-shot reads for probing, continuous background sampling for telemetry | LOW | Expose `.sample_once() -> GPUSample` and `.start() / .stop()` for background thread. Background sampler pushes to a ring buffer (configurable depth, default 60 samples). |

### Differentiators (What Makes This Worth Building vs Calling pynvml Directly)

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| UMA memory model with headroom and jitter margin | DGX Spark's unified memory makes raw available-memory misleading; headroom must account for baseline OS consumption and variance | MEDIUM | Baseline sampling: collect N samples at idle to establish OS baseline consumption. Headroom = MemAvailable - baseline_mean - jitter_margin. Jitter margin = 2 * baseline_stddev (or configurable). This prevents false "enough memory" signals when OS page cache fills during training. |
| Effective scale formula (tier classification) | MFU alone doesn't tell you which performance regime you're in; tier classification maps observable metrics to a named efficiency band | MEDIUM | Effective scale = GPU_util% * clock_ratio * thermal_factor. Clock ratio = current_clock / max_clock. Thermal factor = 1.0 if temp < 75°C, decays linearly to 0.85 at 83°C. Tiers: FULL (>0.85), THROTTLED (0.65–0.85), DEGRADED (0.40–0.65), CRITICAL (<0.40). Industry consensus: "good" MFU is 35–45%; 50%+ is excellent — tiers calibrated around these benchmarks. |
| Anchor store with OOM/COMPLETED/HANG/WATCHDOG override rules | Persistent JSON record of batch configs that worked (COMPLETED) or failed (OOM/HANG/WATCHDOG) so probe results survive restarts | MEDIUM | JSON file at configurable path. Schema: `{model_id: {batch_size: {status, timestamp, notes}}}`. Override rules: OOM at size N → ceiling is N-1; HANG at N → try N/2; WATCHDOG at N → same as HANG; COMPLETED at N → floor is N. Read at probe start, write at probe end. Atomic write (write-then-rename). |
| Probe protocol (prepare/evaluate cycle) | Batch size changes carry risk; probing before committing avoids mid-epoch OOM | HIGH | `probe(model_id, candidate_batch_size)` → `ProbeResult(status, duration_s, peak_memory_bytes)`. Prepare: check anchor store for known-bad configs; check headroom formula. Evaluate: run N steps (default 5 — industry pattern) with candidate size; record peak memory; classify result (COMPLETED/OOM/HANG/TIMEOUT). Write result to anchor store. |
| Failure classifier (clean/oom/hang/thermal/pressure) | Training failures have different root causes; the correct recovery action depends on classification | HIGH | Inputs: exit_code, signal, peak_memory_fraction, temperature, throttle_flags, duration_vs_baseline. Rules: exit_code==OOM or CUDA OOM exception → OOM; temperature > 83°C at failure → THERMAL; duration > 3x baseline with no OOM → HANG; NCCL watchdog signal → WATCHDOG; memory pressure > 90% without OOM exit → PRESSURE; otherwise → CLEAN. Outputs enum + confidence (0–1). |
| /proc/meminfo parser with field caching | Reading /proc/meminfo on every sample adds syscall overhead; fields change slowly for OS baseline | LOW | Parse once per sampling interval. Cache result with TTL (default 500ms). Expose `MemAvailable`, `MemTotal`, `SwapFree`, `Cached`, `Buffers` as typed fields. Handle missing fields gracefully (some container environments strip /proc). |
| dgx_toolbox.py bridge + status.sh GPU block | Integrates with existing DGX Toolbox CLI and status script — telemetry surfaced in `status.sh` output | LOW | `dgx_toolbox.py` gains `telemetry` subcommand: `sample`, `probe`, `anchor`. `status.sh` adds GPU telemetry block: util%, memory used/total, temp, tier. Reuses existing `lib.sh` patterns. |

### Anti-Features (Commonly Requested, Often Problematic)

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Continuous background sampling thread always on | Seems convenient — always have fresh data | Adds CPU overhead to every training run even when telemetry is not needed; can interfere with NCCL timing on tight distributed loops; NVML calls from a background thread can cause driver contention | Explicit start/stop API. Caller opts into background sampling. Default: on-demand sampling only. |
| Auto-adjusting batch size during training | "Smart" adapters that automatically shrink batch size when OOM is detected | Mid-training batch size changes break gradient accumulation math, learning rate schedules, and optimizer state consistency. Databricks' gradient accumulation paper calls this out explicitly | Probe before training starts; pick a safe batch size then hold it constant. Provide anchor store data for next run. |
| GPU metrics exported to Prometheus/OpenTelemetry by default | Observability stacks expect OTEL | Adds external dependencies (OTEL SDK, exporter config, network) to a local-only toolbox; most users don't have a Prometheus instance | Provide a JSONL log output mode that any OTEL collector can ingest. Keep the core library dependency-free. Add an optional `[otel]` extras install path. |
| nvidia-smi subprocess calls as primary data source | Familiar, well-documented | ~100–200ms per call; subprocess spawning blocks the GIL; cannot be called from tight training loops; output format changes between driver versions | pynvml direct NVML calls at ~0.1ms. nvidia-smi is acceptable only for one-shot diagnostic commands, not for sampling loops. |
| Predicting failures before they happen (ML-based predictive maintenance) | Research shows 85% accuracy predicting failures 7 days out | Requires labeled failure history this toolbox doesn't have; adds a training data dependency; far more complexity than the value for a single-node DGX | Reactive classification (classify after failure) + anchor store (avoid known-bad configs). Predictive maintenance is a v2+ consideration once failure logs accumulate. |
| Multi-GPU aggregation | "Sum all GPUs" | DGX Spark has one GB10 integrated GPU — not a multi-GPU discrete system. Aggregation adds complexity with no benefit for this hardware | Single-device sampling. Design the API to be device-index-aware (pass `device_index=0`) so multi-GPU support can be added later without API breakage. |

---

## Feature Dependencies

```
[UMA Memory Model]
    └──requires──> [/proc/meminfo parser]
    └──requires──> [GPUSampler initialization guard]

[Anchor Store]
    └──requires──> [JSON persistence (stdlib only)]

[Probe Protocol]
    └──requires──> [UMA Memory Model] (headroom check before probing)
    └──requires──> [Anchor Store] (read known-bad configs; write results)
    └──requires──> [Failure Classifier] (classify probe outcome)

[Failure Classifier]
    └──requires──> [GPUSampler] (temperature, throttle flags at failure time)
    └──requires──> [UMA Memory Model] (memory pressure fraction)

[Effective Scale Formula]
    └──requires──> [GPUSampler] (util, clock, temp, power)

[dgx_toolbox.py bridge]
    └──requires──> [GPUSampler] (sample subcommand)
    └──requires──> [Probe Protocol] (probe subcommand)
    └──requires──> [Anchor Store] (anchor subcommand)

[status.sh GPU block]
    └──requires──> [dgx_toolbox.py bridge] (calls Python for GPU data)
    └──enhances──> [Effective Scale Formula] (shows tier in status output)
```

### Dependency Notes

- **Probe Protocol requires UMA Memory Model:** The prepare step must check available headroom before attempting a probe — otherwise probes on a nearly-full system will OOM before gathering useful data.
- **Probe Protocol requires Failure Classifier:** The evaluate step needs to classify the probe outcome to decide whether to write OOM/HANG/COMPLETED to the anchor store.
- **Failure Classifier requires GPUSampler:** Classification rules use temperature and throttle flags sampled at the moment of failure, not historic averages.
- **status.sh GPU block requires dgx_toolbox.py bridge:** status.sh is Bash; it cannot call pynvml directly. The Python bridge exposes a `sample --json` output that status.sh can parse.

---

## MVP Definition

### Launch With (v1.3)

Minimum viable set — enough for downstream training scripts to replace their own hardware calls.

- [ ] **GPUSampler** — pynvml init guard, sample_once(), context manager, /proc/meminfo fallback for UMA memory. This is the foundation everything else calls.
- [ ] **UMA Memory Model** — baseline sampling at startup, headroom calculation with jitter margin. Without this, batch size decisions on DGX Spark will be wrong.
- [ ] **Effective scale formula** — util * clock_ratio * thermal_factor → tier enum. Gives training scripts a single number to log.
- [ ] **Anchor store** — JSON persistence, OOM/COMPLETED/HANG/WATCHDOG rules, atomic write. Required by probe protocol.
- [ ] **Probe protocol** — prepare/evaluate cycle, N=5 steps, writes to anchor store. Core value of the milestone.
- [ ] **Failure classifier** — clean/oom/hang/thermal/pressure classification from exit code + sampled metrics. Closes the loop: probe classifies its own outcome.
- [ ] **dgx_toolbox.py bridge** — `telemetry sample`, `telemetry probe`, `telemetry anchor` subcommands. Makes everything accessible from CLI and status.sh.
- [ ] **status.sh GPU telemetry block** — util%, memory, temp, tier in status output. Validates the bridge works end-to-end.

### Add After Validation (v1.3.x)

Features to add once core is exercised by at least one training run.

- [ ] **Background sampler with ring buffer** — needed for continuous logging during long training runs; not needed for the probe use case. Add when a training script needs time-series data.
- [ ] **JSONL telemetry log** — write samples to a rotating JSONL file for post-run analysis. Trigger: someone asks "what happened during that run?"
- [ ] **Per-model baseline profiles** — anchor store extended with per-model memory baselines so headroom calculation can be model-aware. Trigger: probe results differ significantly across model sizes.

### Future Consideration (v2+)

- [ ] **OTEL/Prometheus export** — add as an optional extras dependency once local observability infra exists.
- [ ] **Multi-GPU support** — device_index parameter is already in the API design; implement aggregation when there are multiple GPUs.
- [ ] **Predictive failure modeling** — once 6+ months of anchor store / failure logs accumulate, train a lightweight classifier.

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| GPUSampler (pynvml + /proc fallback) | HIGH | LOW | P1 |
| UMA Memory Model (headroom + jitter) | HIGH | MEDIUM | P1 |
| Anchor Store (JSON persistence) | HIGH | LOW | P1 |
| Probe Protocol (prepare/evaluate) | HIGH | MEDIUM | P1 |
| Failure Classifier | HIGH | MEDIUM | P1 |
| Effective Scale Formula | MEDIUM | LOW | P1 |
| dgx_toolbox.py bridge | MEDIUM | LOW | P1 |
| status.sh GPU block | MEDIUM | LOW | P1 |
| Background sampler / ring buffer | MEDIUM | LOW | P2 |
| JSONL telemetry log | LOW | LOW | P2 |
| Per-model memory baselines | MEDIUM | MEDIUM | P2 |
| OTEL/Prometheus export | LOW | MEDIUM | P3 |
| Predictive failure modeling | LOW | HIGH | P3 |

**Priority key:**
- P1: Must have for v1.3 launch
- P2: Should have, add when possible (v1.3.x)
- P3: Nice to have, future consideration (v2+)

---

## Competitor / Prior Art Analysis

There is no off-the-shelf library that combines all six primitives for single-node local training on UMA hardware. Existing tools cover subsets:

| Capability | nvidia-smi | pynvml direct | nvitop | Hugging Face Trainer | Our Approach |
|------------|------------|---------------|--------|----------------------|--------------|
| GPU util / temp / power | Yes (subprocess) | Yes (API) | Yes (API, TUI) | Partial (via torch) | pynvml API, no subprocess |
| UMA /proc/meminfo fallback | No | No | No | No | Yes — DGX Spark-specific |
| Headroom with jitter margin | No | No | No | No | Yes |
| Effective scale tier | No | No | No | No | Yes |
| Anchor store for batch configs | No | No | No | No | Yes |
| Probe protocol | No | No | No | Partial (auto-shrink, problematic) | Yes — safe prepare/evaluate |
| Failure classification | No | No | No | No | Yes |
| No external deps beyond pynvml | N/A | Yes | No (curses, psutil) | No (full HF stack) | Yes — stdlib + pynvml only |

The Hugging Face Trainer has auto-batch-size finding via `auto_find_batch_size=True` (uses Accelerate's OOM-catch-and-retry). This is the anti-feature described above — it changes batch size mid-training. The probe protocol here does not do that: it probes before training, then holds the result constant.

---

## Sources

- [NVML Support for DGX Spark Grace Blackwell Unified Memory — NVIDIA Developer Forums](https://forums.developer.nvidia.com/t/nvml-support-for-dgx-spark-grace-blackwell-unified-memory-community-solution/358869)
- [DGX Spark Known Issues — NVIDIA Docs](https://docs.nvidia.com/dgx/dgx-spark/known-issues.html)
- [Unexpected Available Memory Reporting on DGX Spark — NVIDIA Customer Help](https://nvidia.custhelp.com/app/answers/detail/a_id/5728/~/unexpected-available-memory-reporting-on-dgx-spark)
- [vLLM UMA memory bug — nvmlDeviceGetMemoryInfo Not Supported on DGX Spark](https://github.com/vllm-project/vllm/issues/35313)
- [NVML API Reference — nvmlDeviceGetCurrentClocksThrottleReasons](https://docs.nvidia.com/deploy/nvml-api/group__nvmlClocksThrottleReasons.html)
- [Farewell CUDA OOM: Automatic Gradient Accumulation — Databricks](https://www.databricks.com/blog/farewell-oom)
- [Decoding GPU Efficiency: The FLOPs Fallacy — Clockwork](https://clockwork.io/blog/decoding-gpu-efficiency-part-1-the-flops-fallacy/)
- [Model FLOPs Utilization (MFU) — Better ML / Medium](https://medium.com/better-ml/using-model-flops-utilization-mfu-7b17de07faec)
- [GPU Performance Background — NVIDIA Deep Learning Docs](https://docs.nvidia.com/deeplearning/performance/dl-performance-gpu-background/index.html)
- [Detecting GPU Failures Before They Corrupt AI Training — Hyperbolic](https://www.hyperbolic.ai/blog/gpu-failure-signs)
- [Characterizing GPU Resilience — arXiv 2503.11901](https://arxiv.org/html/2503.11901v1)
- [A Batch Too Large: Finding the Batch Size That Fits on GPUs — Medium](https://medium.com/data-science/a-batch-too-large-finding-the-batch-size-that-fits-on-gpus-aef70902a9f1)
- [pynvml — PyPI](https://pypi.org/project/pynvml/)
- [How to Monitor GPU Utilization for ML Workloads with OpenTelemetry — OneUptime 2026](https://oneuptime.com/blog/post/2026-02-06-monitor-gpu-utilization-ml-workloads-opentelemetry/view)

---

*Feature research for: GPU telemetry primitives (dgx_toolbox v1.3)*
*Researched: 2026-04-01*
