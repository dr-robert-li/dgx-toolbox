# Pitfalls Research

**Domain:** GPU telemetry primitives and adaptive training support added to existing DGX Spark toolbox
**Researched:** 2026-04-01
**Confidence:** HIGH for pynvml/GB10 UMA behavior (verified against NVIDIA official docs, NVIDIA Developer Forum community solutions, GitHub issues across multiple projects); HIGH for /proc/meminfo parsing (verified against kernel manual, Oracle Linux blog, Red Hat docs); HIGH for PyTorch OOM reference leak (official PyTorch docs and multiple issue threads); MEDIUM for anchor store concurrency patterns (general atomic-write literature); MEDIUM for effective scale formula correctness (Unsloth blog, community discussions); LOW for thermal classification specifics on GB10 (limited GB10-specific thermal API documentation found)

---

## Critical Pitfalls

### Pitfall 1: nvmlDeviceGetMemoryInfo Returns "Not Supported" on GB10 — No Graceful Fallback

**What goes wrong:**
`pynvml.nvmlDeviceGetMemoryInfo(handle)` raises `NVMLError_NotSupported` (or the equivalent `NVML_ERROR_NOT_SUPPORTED`) on the DGX Spark GB10 because the unified memory architecture has no dedicated framebuffer. Code that calls this function without a try/except will crash. Worse, code that catches only `RuntimeError` will still crash because pynvml raises its own exception hierarchy. Tools like HAMi's device plugin have exhibited panic/crash behavior from exactly this uncaught error in production.

nvidia-smi also explicitly reports "Memory-Usage: Not Supported" on iGPU platforms — this is documented in the official DGX Spark User Guide as expected behavior, not a bug.

**Why it happens:**
Developers test on discrete-GPU workstations (RTX, A100, H100) where `nvmlDeviceGetMemoryInfo` always succeeds. They add a GPU sampler and it works in local testing. When the sampler runs on the DGX Spark GB10, the first call throws an unhandled exception and the entire GPUSampler crashes.

**How to avoid:**
Wrap every `nvmlDeviceGetMemoryInfo` call in a `try/except pynvml.NVMLError` block (not `except Exception`, not `except RuntimeError`). On `NVMLError_NotSupported`, fall back to `/proc/meminfo` UMA parsing. Document this as the expected path for UMA hardware. The community NVML shim solution (CUDA Runtime API + `/proc/meminfo` for unified memory queries) is the correct architectural pattern.

```python
try:
    mem = pynvml.nvmlDeviceGetMemoryInfo(handle)
    total, used, free = mem.total, mem.used, mem.free
except pynvml.NVMLError:
    # UMA fallback: GB10 has no dedicated framebuffer
    total, used, free = _read_proc_meminfo_uma()
```

**Warning signs:**
- `NVMLError_NotSupported` or `NVMLError: Not Supported` in any traceback
- `nvidia-smi` shows `N/A` or `Not Supported` for memory columns on the DGX Spark
- GPUSampler unit tests pass on CI (x86_64) but the sampler crashes at runtime on the DGX Spark

**Phase to address:**
Phase 1 (GPUSampler implementation) — the fallback path is the primary code path on this hardware and must be built from the start, not retrofitted.

---

### Pitfall 2: cudaMemGetInfo Underreports Available Memory on UMA — Misses Reclaimable SWAP

**What goes wrong:**
`torch.cuda.mem_get_info()` and the underlying `cudaMemGetInfo` API return values that are smaller than actual allocatable memory on the DGX Spark because the API "does not account for memory that could potentially be reclaimed from SWAP." This is documented in the official DGX Spark User Guide. If the UMA headroom calculation uses `cudaMemGetInfo` as the source of truth, it will underestimate available memory, causing the adaptive training system to refuse larger batch sizes that would actually succeed.

**Why it happens:**
`cudaMemGetInfo` was designed for discrete GPU memory and reports only the current allocatable CUDA pool. On a UMA system where CPU DRAM and GPU memory are the same physical pool, SWAP reclamation represents a real expansion of available capacity that this API ignores.

**How to avoid:**
Use `/proc/meminfo` as the authoritative source for total system memory on GB10. Specifically:
- Read `MemAvailable` (not `MemFree`) for available headroom — it accounts for reclaimable page cache and slab
- Read `SwapFree` and add a configurable fraction as bonus headroom (NVIDIA's own guidance)
- Do not trust `cudaMemGetInfo` for capacity planning on UMA hardware; use it only for currently allocated CUDA pool sizes if needed

**Warning signs:**
- Headroom calculation reports <30GB available when `nvidia-smi` or `/proc/meminfo` shows much more
- Probe protocol rejects batch sizes that actually succeed when tried manually
- `MemAvailable` in `/proc/meminfo` is consistently much larger than what `cudaMemGetInfo` reports

**Phase to address:**
Phase 1 (GPUSampler) and Phase 2 (UMA memory model) — headroom formula must use `/proc/meminfo` from the first iteration.

---

### Pitfall 3: /proc/meminfo Parsing Uses MemFree Instead of MemAvailable — Grossly Underestimates Free Memory

**What goes wrong:**
Code reads `MemFree` from `/proc/meminfo` and uses it as "available memory." On a DGX Spark running a training workload, the Linux kernel aggressively fills available DRAM with page cache (model weight files, dataset mmaps, log files). `MemFree` can show as low as 1-2GB while `MemAvailable` shows 40GB. The GPUSampler reports severe memory pressure when none exists, the failure classifier misclassifies normal training runs as OOM-pressure events, and the probe protocol refuses all batch size increases.

**Why it happens:**
`MemFree` is the most visible field and the most intuitive name. Developers use it without reading the kernel documentation. The old formula `free + cached` is documented as "wrong on modern kernels" (Red Hat, Oracle Linux, kernel manual) but continues to appear in example code because it was correct before Linux 3.14.

`MemAvailable` has been the correct field since Linux 3.14. It accounts for page cache reclaimable, reclaimable slab, and zone watermarks — the kernel's own estimate of how much memory can actually be freed for a new allocation.

**How to avoid:**
Always parse `MemAvailable`, not `MemFree`:
```python
def _read_memavailable_kb() -> int:
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemAvailable:"):
                return int(line.split()[1])
    raise RuntimeError("MemAvailable not found in /proc/meminfo")
```
Add a unit test that compares `MemFree` vs `MemAvailable` on the DGX Spark under load and asserts they can differ by >10x. This makes the distinction visible in the test suite.

**Warning signs:**
- Reported available memory matches `MemFree` (usually low under load) rather than `MemAvailable`
- Memory pressure alarms trigger while `free -h` shows large `available` column
- On an otherwise idle system, free shows `MemFree` as low as 100MB but `MemAvailable` as 90GB

**Phase to address:**
Phase 1 (GPUSampler) — the parsing function is the foundation of the UMA model; getting this wrong invalidates all downstream calculations.

---

### Pitfall 4: Page Cache Jitter Makes Memory Baseline Unstable — Sampling at the Wrong Time

**What goes wrong:**
Baseline memory sampling is done once at startup or at the start of a training job. The Linux kernel's buffer cache fluctuates by several GB in the seconds after model loading completes, as the kernel progressively caches model weight files. A baseline sampled too early reads inflated "used" values. A baseline sampled just after cache pressure relief reads deflated values. The UMA jitter margin calculation is defeated by a single-point-in-time sample.

On a DGX Spark training a 70B model, buffer cache pressure from model file loading can create 10-20GB of transient page cache population that evaporates within 60 seconds of training start. Any baseline sample taken during this window is garbage.

**Why it happens:**
Developers run the baseline sampler once, see a reasonable number, and proceed. The variance only becomes visible after collecting multiple baseline samples over time or observing the sampler during a large model load event.

**How to avoid:**
- Take baseline memory samples as a rolling window (e.g., median of 10 samples over 30 seconds) rather than a single point-in-time read
- Always read `Buffers` and `Cached` from `/proc/meminfo` alongside `MemAvailable` to detect whether a cache-heavy transient is in progress; if `Buffers + Cached` is >20% of total and dropping, wait for stabilization before committing a baseline
- Apply a configurable jitter margin (e.g., 2GB) to all headroom calculations to absorb normal page cache variance
- Document the baseline as "stable after training loop iteration 1 completes" not "sampled at process start"

**Warning signs:**
- Baseline memory values differ by >5GB between two runs of the same training configuration
- Baseline reads taken 10 seconds apart on the same workload differ significantly
- `Buffers` + `Cached` in `/proc/meminfo` drops visibly between samples

**Phase to address:**
Phase 2 (UMA memory model) — rolling baseline and jitter margin are core model features, not optimizations.

---

### Pitfall 5: pynvml Library Package Confusion — pynvml vs nvidia-ml-py

**What goes wrong:**
The codebase installs `pynvml` (the `gpuopenanalytics` fork on PyPI) but imports from it expecting the behavior and API of `nvidia-ml-py` (the official NVIDIA binding). These are separate packages with different import names, different version histories, and different error types in some versions. Mixing them in requirements or in documentation causes import failures or silent behavioral differences.

Additionally, `pynvml` (the older fork) is effectively deprecated — the official NVIDIA package is `nvidia-ml-py` and its import is also `pynvml`. Installing both in the same environment causes one to shadow the other unpredictably.

**Why it happens:**
Both packages expose `import pynvml` as their top-level namespace. Documentation and tutorials use both names interchangeably. `pip install pynvml` installs the fork; `pip install nvidia-ml-py` installs the official package. The distinction is non-obvious.

**How to avoid:**
Pin `nvidia-ml-py` in `pyproject.toml` or `requirements.txt`, not `pynvml`. Verify the installed package in CI:
```bash
pip show nvidia-ml-py  # should show the official NVIDIA package
pip show pynvml        # should NOT be installed
```
Add a comment in requirements explaining which package is canonical.

**Warning signs:**
- `pip install pynvml` was used instead of `pip install nvidia-ml-py`
- Both `pynvml` and `nvidia-ml-py` appear in `pip list` output
- `NVMLError` exception hierarchy behaves differently than expected in error handling

**Phase to address:**
Phase 1 (GPUSampler) — pin the correct package before writing the first import.

---

### Pitfall 6: PyTorch OOM Exception Handler Holds References — Memory Never Freed for Retry

**What goes wrong:**
The probe protocol catches a CUDA OOM exception to trigger rollback, then attempts to retry with a smaller batch size. The retry OOMs immediately even though sufficient memory should exist. The root cause: Python's exception handling keeps a reference to the stack frame where the OOM was raised, which keeps all the tensors in that frame alive. CUDA memory is not freed until the exception object goes out of scope.

This is a documented PyTorch issue (GitHub #27600, #82218) with a well-known pattern: recovery code inside the `except` block cannot free CUDA memory because the exception object itself holds references.

**Why it happens:**
```python
# WRONG — retrying inside except block; tensors from failed forward still allocated
try:
    loss = model(batch)
except torch.cuda.OutOfMemoryError:
    torch.cuda.empty_cache()
    loss = model(smaller_batch)  # OOMs again
```
The exception object `e` in the except clause references the traceback, which references the stack frame, which holds all intermediate tensors.

**How to avoid:**
Move all recovery logic outside the except block using a flag:
```python
oom = False
try:
    loss = model(batch)
except torch.cuda.OutOfMemoryError:
    oom = True
    torch.cuda.empty_cache()
    gc.collect()

if oom:
    loss = model(smaller_batch)  # Now previous tensors are freed
```
The probe protocol's rollback implementation must follow this pattern exactly.

**Warning signs:**
- Retry after OOM fails immediately with another OOM
- `torch.cuda.memory_allocated()` immediately after `empty_cache()` inside the except block still shows high allocation
- OOM recovery works in a REPL session but not inside the training loop

**Phase to address:**
Phase 4 (Probe protocol) — the OOM recovery pattern is the structural foundation of the probe cycle; establish it before any probe logic.

---

### Pitfall 7: Anchor Store JSON Corruption from Concurrent Writes

**What goes wrong:**
Two training processes (or a sampler background thread and the main training process) write to the anchor store JSON file simultaneously. One process truncates the file while the other is mid-read. The result is truncated or malformed JSON. On the next read, `json.loads()` raises `JSONDecodeError`, the anchor store fails to initialize, and the entire adaptive batch sizing system falls back to defaults or crashes — silently losing all previously anchored configs.

This exact failure mode has been documented in production systems including Claude Code's `.claude.json` (GitHub Issues #29051, #29217).

**Why it happens:**
Python's `open(path, 'w') + json.dump()` is a two-step operation (truncate then write). A concurrent read between those two steps sees an empty or partial file.

**How to avoid:**
Use atomic write via write-to-temp-then-rename:
```python
import tempfile, os

def _atomic_write_json(path: str, data: dict) -> None:
    dir_ = os.path.dirname(path)
    with tempfile.NamedTemporaryFile('w', dir=dir_, delete=False, suffix='.tmp') as f:
        json.dump(data, f, indent=2)
        tmp_path = f.name
    os.replace(tmp_path, path)  # atomic on POSIX
```
`os.replace()` is atomic on Linux (wraps `rename(2)` which is atomic per POSIX). This prevents partial reads.

Also add a `.bak` pattern: on every successful write, copy the previous version to `anchor_store.json.bak`. On `JSONDecodeError` during load, fall back to `.bak` before raising.

**Warning signs:**
- `JSONDecodeError` appears in sampler or training logs
- Anchor store file is 0 bytes on disk
- Adaptive batch sizing reverts to defaults unexpectedly mid-training run

**Phase to address:**
Phase 3 (Anchor store) — atomic writes must be the only write path; this cannot be added later without risk of existing data corruption.

---

### Pitfall 8: Stale Anchor Entries Not Keyed on Hardware Config — Wrong Batch Sizes After Environment Change

**What goes wrong:**
The anchor store persists batch configs keyed only on model name (e.g., `"llama-3-8b": {"batch_size": 32}`). The user upgrades from a Docker container with 60GB available to a container with 100GB available (different `--ulimit memlock`, or same machine but different competing workloads). The anchor store still returns the conservative batch size from the constrained environment. The probe protocol is never triggered because the anchor exists.

The inverse is more dangerous: an anchor from a high-memory environment is loaded in a constrained environment, the anchor batch size causes immediate OOM, and the failure classifier sees a hang/restart loop.

**Why it happens:**
Model name is the obvious primary key. Hardware state is dynamic and harder to capture. Developers defer "hardware keying" as a future enhancement, but the deferred version never ships and the stale anchors accumulate.

**How to avoid:**
Key anchors on a composite key: `{model_name}_{memory_tier}` where `memory_tier` is a coarse bucket (e.g., `"<64GB"`, `"64-100GB"`, `"100GB+"`) derived from total system memory at anchor-write time. Store the total memory snapshot alongside the anchored config so staleness is detectable. Add an expiry: anchors older than N days (configurable, default 30) are treated as unanchored and trigger a new probe.

```json
{
  "llama-3-8b_100GB+": {
    "batch_size": 32,
    "anchored_at": "2026-04-01T10:00:00Z",
    "memory_total_gb": 128,
    "expires_at": "2026-05-01T10:00:00Z"
  }
}
```

**Warning signs:**
- Anchor store has entries that are months old
- After a container rebuild, batch sizes are immediately accepted from the store without probing
- OOM occurs on first training step despite the anchor store claiming the config is safe

**Phase to address:**
Phase 3 (Anchor store) — key schema and expiry must be designed before any entries are written; changing the key schema after production use requires a migration.

---

### Pitfall 9: Effective Scale Formula Applies Multiplier to Physical Batch Size — Ignores Gradient Accumulation Steps

**What goes wrong:**
The effective scale formula calculates "effective batch size" but the user has configured `gradient_accumulation_steps > 1`. The formula applies its tier multiplier to the physical micro-batch size, not the effective batch size (`micro_batch * grad_accum_steps`). The tier boundary comparisons are therefore off by the accumulation factor. A config that should land in the "high" tier is classified as "medium", triggering a probe that is unnecessary and potentially disruptive.

**Why it happens:**
The formula is derived from memory pressure logic (what fits in a single forward pass), so `micro_batch_size` is the natural input. The relationship to `effective_batch_size` is added as an afterthought. The confusion is compounded by the Unsloth/Hugging Face bug (2024) where gradient accumulation loss averaging was wrong — the community awareness of effective-vs-micro batch semantics is inconsistent.

**How to avoid:**
Define clearly in the formula's interface which concept is being classified:
- Tier boundaries operate on **physical micro-batch size** (memory impact)
- Effective scale reporting uses **effective batch size** (training dynamics impact)
- Never mix these in a single formula without explicit documentation

Document the formula's inputs and outputs with concrete examples at each tier boundary. Add a unit test that passes `micro_batch=4, grad_accum=8` and asserts the memory-tier classification uses 4, while the effective-batch reporting emits 32.

**Warning signs:**
- Tier boundaries change unexpectedly when `gradient_accumulation_steps` is changed without changing `per_device_train_batch_size`
- Probe protocol triggers unnecessarily after switching from `bs=16, ga=1` to `bs=4, ga=4`
- Formula comments use "batch size" without specifying micro vs effective

**Phase to address:**
Phase 2 (Effective scale formula) — the semantic distinction must be documented in the formula's type signature and docstring before the formula is used by any downstream component.

---

### Pitfall 10: Hang vs OOM Misclassification — Exit Code 137 Is Ambiguous

**What goes wrong:**
The failure classifier sees exit code 137 (SIGKILL) and classifies the failure as OOM (killed by the Linux OOM killer). However, exit code 137 is also produced by a watchdog timer sending SIGKILL to a hung process, by `docker stop` (which sends SIGTERM then SIGKILL after timeout), and by the user running `kill -9` manually. Classifying a watchdog-killed hang as an OOM incorrectly triggers OOM override rules in the anchor store (reducing batch size) when the correct response would be hang-investigation or watchdog extension.

**Why it happens:**
The Linux OOM killer sends SIGKILL, and its canonical exit code is 137 (128 + signal 9). This is documented and widely cited. The possibility that other sources also send SIGKILL is less prominent in training-failure discussions.

**How to avoid:**
Multi-signal classification — do not rely on exit code alone:

| Signal | Exit Code | Supplementary Evidence | Classification |
|--------|-----------|----------------------|----------------|
| SIGKILL | 137 | `dmesg` contains "Out of memory: Killed process" | OOM |
| SIGKILL | 137 | No dmesg OOM line; process ran for >N minutes before kill | HANG/WATCHDOG |
| SIGKILL | 137 | `docker stop` issued; container logs show graceful warning | EXTERNAL_STOP |
| SIGTERM | 130/143 | Normal shutdown pattern | CLEAN |

Parse `dmesg` (or `/var/log/kern.log`) for OOM killer messages keyed on the training process PID. If the kernel OOM message is absent but exit code is 137, classify as HANG or WATCHDOG, not OOM. The difference matters because OOM triggers batch-size reduction while HANG should not.

**Warning signs:**
- Batch size is being reduced after jobs that were externally stopped or timed out by a job scheduler
- `dmesg` does not contain OOM lines corresponding to the classified OOM events
- Hang events never appear in the failure log — everything is classified as OOM

**Phase to address:**
Phase 5 (Failure classifier) — the multi-signal classification schema must be established before the anchor store OOM override rules are written; changing the classification schema after override rules are deployed requires careful migration.

---

### Pitfall 11: Probe Protocol Leaves Model in Inconsistent State on Failure — No Optimizer State Rollback

**What goes wrong:**
The probe protocol runs a prepare/evaluate cycle to test a new batch size. During the evaluate phase, an OOM occurs after optimizer state has been partially updated (or after a gradient step completes). The probe does not roll back the optimizer state or model weights. The training loop resumes from a partially-updated model rather than the pre-probe checkpoint. Depending on the loss function, this can corrupt training silently (loss continues decreasing so no alarm fires) or cause loss divergence that is attributed to hyperparameters rather than the probe.

**Why it happens:**
The probe is designed as a "test forward pass" that should be rollback-trivially. But in eager execution PyTorch, a forward pass that includes loss computation and `backward()` has already updated gradient buffers. If the probe runs a full step (forward + backward + optimizer step), rolling back requires checkpointing the optimizer state before the probe — an expensive operation.

**How to avoid:**
Design probe phases strictly:
- **Prepare phase:** Only forward pass, no `loss.backward()`, no `optimizer.step()`. Use `with torch.no_grad():` to prevent gradient computation.
- **Evaluate phase:** Measure memory after forward pass only. If memory is acceptable, declare the probe successful and let the real training loop run the backward pass.
- Never run `optimizer.step()` inside the probe cycle.
- If the probe must test backward (to catch activation memory OOM), snapshot optimizer state before the probe and restore on any failure.

Document this constraint in the probe interface (`ProbeProtocol.evaluate()` docstring): "Probe does not execute optimizer.step(). Successful probe guarantees only that forward + backward memory fits."

**Warning signs:**
- Loss spikes or diverges immediately after a probe cycle completes
- Probe cycles that include a gradient step (logs show "optimizer step" inside probe)
- Model checkpoint after probe differs from checkpoint before probe when probe is expected to be no-op

**Phase to address:**
Phase 4 (Probe protocol) — the no-optimizer-step constraint must be in the interface specification before implementation begins.

---

### Pitfall 12: GPUSampler Polling Loop Uses subprocess Calls — Performance and Reliability Issues

**What goes wrong:**
GPUSampler is implemented using `subprocess.run(["nvidia-smi", ...])` inside a tight polling loop. On the DGX Spark, `nvidia-smi` is itself an NVML wrapper and carries 50-150ms subprocess startup overhead per call. At a 1-second sampling interval, subprocess overhead consumes 5-15% of each interval just in process creation. At faster intervals (100ms for probe evaluation), the sampler loop can barely keep up with its own invocations. Additionally, subprocess calls are not unit-testable without mocking the entire subprocess infrastructure.

The PROJECT.md specification explicitly states "no subprocess calls" for the GPUSampler.

**Why it happens:**
`nvidia-smi` is the most documented GPU monitoring approach. Developers default to it before discovering the NVML Python bindings. The pynvml/nvidia-ml-py wrapper eliminates subprocess overhead entirely and is directly mockable in unit tests.

**How to avoid:**
Use `nvidia-ml-py` (pynvml) exclusively for all NVML calls. No subprocess invocations. All calls go through the Python bindings, which call the shared library directly via ctypes. This is the canonical approach for monitoring tools (nvitop, gpustat, nvidia-smi itself are all built on NVML).

**Warning signs:**
- `subprocess`, `Popen`, or `shlex` imports in the GPUSampler module
- `"nvidia-smi"` string literal in GPUSampler source
- Sampler poll intervals slower than expected under light load

**Phase to address:**
Phase 1 (GPUSampler) — this is a specification requirement; catch it in code review before any implementation lands.

---

## Technical Debt Patterns

Shortcuts that seem reasonable but create long-term problems.

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Using `MemFree` instead of `MemAvailable` from `/proc/meminfo` | Simple one-field parse | Underreports available memory by 10-50x under load; causes false OOM pressure alarms | Never |
| Single-point-in-time baseline instead of rolling window | One read instead of 10 | Baseline corrupted by page cache transients during model load; jitter margin useless | Never |
| Keying anchor store only on model name | Simple key | Stale entries from different memory environments applied silently | Only acceptable as an MVP if an expiry TTL is also implemented |
| `open(path, 'w')` for anchor store writes | Two lines of code | Corruption on concurrent write; undetectable without explicit testing | Never — atomic write is equally simple |
| Subprocess to `nvidia-smi` instead of pynvml | Familiar tool, easy to prototype | 50-150ms overhead per sample; not mockable; breaks on GB10 for memory fields | Acceptable only in a throwaway script, never in the GPUSampler |
| Catching `Exception` in OOM handler instead of `torch.cuda.OutOfMemoryError` | Catches more errors | Masks non-OOM exceptions; Python reference leak same either way | Never — be specific |
| Anchor entries without expiry TTL | Zero clock management | Stale anchors from 6 months ago applied to changed hardware | Never — 30-day default TTL costs nothing |
| Classifying all SIGKILL as OOM | Simple rule | Hang events trigger batch-size reduction; corrupts anchor store with wrong failure type | Never when dmesg is available |

---

## Integration Gotchas

Common mistakes when connecting to the existing DGX Toolbox infrastructure.

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| pynvml on GB10 | Calling `nvmlDeviceGetMemoryInfo` without NVMLError fallback | Wrap in `try/except pynvml.NVMLError` and fall through to `/proc/meminfo` UMA path |
| `/proc/meminfo` parsing | Reading `MemFree` as available memory | Always read `MemAvailable`; add `Buffers` + `Cached` reads for transient detection |
| `cudaMemGetInfo` on UMA | Treating result as authoritative available memory | Use as secondary signal only; `/proc/meminfo MemAvailable + SwapFree` is authoritative |
| anchor store + existing `lib.sh` pattern | Storing anchor file in a directory without write guarantees | Store in `~/.config/dgx-toolbox/` or alongside the model; verify write permissions at startup |
| dgx_toolbox.py bridge | Adding GPU telemetry imports at module top level | Wrap in `try/except ImportError` so the bridge degrades gracefully if pynvml is absent |
| status.sh GPU telemetry block | Calling Python telemetry from status.sh without checking Python environment | Add a guard: `if command -v python3 >/dev/null && python3 -c "import pynvml" 2>/dev/null; then` |
| failure classifier + training launcher scripts | Checking only process exit code | Check exit code + `dmesg` OOM lines + NVML temperature to classify correctly |
| probe protocol + Unsloth training | Running probe inside the Unsloth training loop | Probe must run before Unsloth's `Trainer.train()` is called; Unsloth manages its own CUDA state |

---

## Performance Traps

Patterns that work at small scale but fail as usage grows.

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Single-sample `/proc/meminfo` read as baseline | Baseline variance >5GB between runs of same config | Rolling window (10 samples / 30 seconds); wait for cache stabilization | Immediately on large model loads (>30B parameters) |
| Anchor store loaded/saved on every sample poll | High I/O rate on NVMe; lock contention | Load at startup; save only on state change; use atomic write | At 1Hz sampling rate with frequent updates |
| pynvml handle opened and closed per sample | NVML overhead; handle creation latency | Open once at GPUSampler init; close only at shutdown | At sampling rates >0.5Hz |
| Failure classifier reading full dmesg | dmesg can be 50MB+; slow parse | Read last N lines only; filter by timestamp window matching training job | On systems with months of uptime |
| Probe protocol testing every batch size increment | Linear probe time O(N) before each training run | Binary-search between last successful anchor and current candidate | When batch size search space >32 options |
| Anchor store grows unbounded | File size grows; load time increases | TTL-based expiry; cap at N entries per model; prune on load | After 6+ months and 10+ models |

---

## Security Mistakes

Domain-specific security issues for GPU telemetry in a shared DGX toolbox.

| Mistake | Risk | Prevention |
|---------|------|------------|
| Anchor store world-writable | Any process on the system can inject fake "safe" batch configs, causing OOM on next run | chmod 600 on anchor store file; verify on every load |
| Parsing unsanitized `/proc/meminfo` lines | Not a real attack vector, but defensive parsing avoids crashes from kernel version differences | Use explicit field parsing, not eval or split-with-assumption |
| Probe protocol exposing model intermediate activations to logs | Debug logging of probe tensors leaks model weights or training data embeddings | Log only scalar metrics (batch size, memory used, success/fail); never log tensor values |
| dmesg parsing without privilege check | On some systems, `dmesg` requires root or `CAP_SYSLOG`; silent failure returns empty, all OOMs misclassified as hangs | Check dmesg readability at startup; log a warning and adjust classifier behavior if unavailable |

---

## UX Pitfalls

Common mistakes in the operator/developer experience for this telemetry layer.

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Telemetry block in status.sh shows raw bytes | Numbers like "127926272000" are unreadable | Always convert to GiB for display; keep raw bytes in data structures |
| Anchor store shows no expiry information | Users don't know if they're using a stale anchor | Display `anchored_at` and `expires_at` in status output |
| GPUSampler errors crash status.sh | A single pynvml error makes the entire status script fail | GPUSampler errors in status.sh context must be caught and displayed as "telemetry unavailable" |
| Failure classifier emits only final verdict | Debugging misclassifications requires knowing which signals were checked | Log all classifier signals (exit code, dmesg match, temperature) alongside the final verdict |
| Probe protocol "silent success" | Users don't know a probe ran or what batch size was anchored | Log probe start/end and the anchored result to stdout and the dgx-toolbox log |

---

## "Looks Done But Isn't" Checklist

- [ ] **GPUSampler on GB10:** Verify `nvmlDeviceGetMemoryInfo` fallback fires by running the sampler with pynvml mocked to raise `NVMLError_NotSupported`; assert the `/proc/meminfo` path is invoked
- [ ] **MemAvailable vs MemFree:** Verify by checking the parsing function under load; assert the returned value matches `MemAvailable` in `/proc/meminfo`, not `MemFree`
- [ ] **Atomic anchor write:** Verify no partial-write corruption by running concurrent writer + reader in a unit test; assert `json.loads()` never raises `JSONDecodeError` on concurrent access
- [ ] **Anchor expiry:** Verify by seeding an anchor with an `expires_at` in the past; assert it is treated as absent on next load
- [ ] **Probe no-optimizer-step:** Verify by confirming `optimizer.step()` is never called inside the probe cycle; add an assertion or mock that fails if it is called
- [ ] **OOM recovery outside except block:** Verify by inserting a manual OOM in a test and confirming the retry allocates successfully; confirm `torch.cuda.memory_allocated()` drops before the retry
- [ ] **Exit code 137 disambiguation:** Verify the classifier distinguishes OOM from hang by testing with a mock that returns 137 with and without a matching dmesg OOM line
- [ ] **Effective scale formula micro vs effective batch:** Verify by running formula with `micro_batch=4, grad_accum=8` and asserting tier classification uses 4, effective scale reports 32
- [ ] **status.sh guard for pynvml absent:** Verify status.sh does not crash when `import pynvml` fails; the GPU block should show "telemetry unavailable" not a Python traceback
- [ ] **nvidia-ml-py not pynvml installed:** Verify `pip show nvidia-ml-py` succeeds and `pip show pynvml` is absent in the project venv

---

## Recovery Strategies

When pitfalls occur despite prevention, how to recover.

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| nvmlDeviceGetMemoryInfo crash on GB10 | LOW | Add try/except NVMLError with /proc/meminfo fallback; redeploy; no data loss |
| MemFree used instead of MemAvailable | LOW | Change one field name in parsing function; all calculations self-correct on next sample |
| Corrupt anchor store JSON | LOW | Delete anchor store file; system falls back to unanchored defaults; probe runs on next training start |
| Stale anchors causing OOM | MEDIUM | Delete affected anchor entries; add hardware-keyed composite key; add expiry TTL; rerun probes |
| Probe corrupted optimizer state | HIGH | Roll back to pre-probe checkpoint; add `torch.no_grad()` guard to probe; verify checkpoint save precedes any probe |
| Misclassified hangs reducing batch size | MEDIUM | Audit anchor store OOM entries against dmesg history; correct misclassified entries; add dmesg check to classifier |
| All SIGKILL classified as OOM — batch size spiraling down | MEDIUM | Reset anchor store; implement multi-signal classifier; add a floor to prevent batch size going below minimum viable |
| pynvml vs nvidia-ml-py conflict in venv | LOW | `pip uninstall pynvml`; `pip install nvidia-ml-py`; verify imports work |

---

## Pitfall-to-Phase Mapping

How roadmap phases should address these pitfalls.

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| nvmlDeviceGetMemoryInfo on GB10 | Phase 1 (GPUSampler) | Unit test: mock NVMLError_NotSupported; assert /proc/meminfo path invoked |
| cudaMemGetInfo underreports UMA | Phase 1 (GPUSampler) + Phase 2 (UMA model) | Assert headroom calculation uses /proc/meminfo MemAvailable, not cudaMemGetInfo |
| MemFree vs MemAvailable | Phase 1 (GPUSampler) | Unit test: parse real /proc/meminfo; assert field is MemAvailable |
| Page cache jitter in baseline | Phase 2 (UMA memory model) | Baseline sampler takes 10 samples; asserts median vs single-point differ <5% on stable system |
| pynvml package confusion | Phase 1 (environment setup) | CI check: pip show nvidia-ml-py succeeds; pip show pynvml absent |
| PyTorch OOM reference leak | Phase 4 (Probe protocol) | Unit test: probe OOM recovery; assert successful retry after 137 ms, not immediate second OOM |
| Anchor store JSON corruption | Phase 3 (Anchor store) | Concurrent write stress test; assert no JSONDecodeError in 1000 concurrent writes |
| Stale anchors from different hardware | Phase 3 (Anchor store) | Anchor key includes memory tier; expiry TTL enforced; unit test with past-expiry anchor |
| Effective scale formula confusion | Phase 2 (Effective scale formula) | Unit test with micro_batch=4, grad_accum=8; assert tier uses 4, effective reports 32 |
| Hang vs OOM misclassification | Phase 5 (Failure classifier) | Unit test: exit 137 with no dmesg OOM → HANG; exit 137 with dmesg OOM → OOM |
| Probe optimizer state corruption | Phase 4 (Probe protocol) | Assert no optimizer.step() called in probe; mock test confirms pre-probe weights == post-probe-failure weights |
| subprocess in GPUSampler | Phase 1 (GPUSampler) | Grep for subprocess/Popen in sampler source; CI linting rule |

---

## Sources

- [NVIDIA Developer Forums: NVML Support for DGX Spark Grace Blackwell Unified Memory — Community Solution (2026-01-28)](https://forums.developer.nvidia.com/t/nvml-support-for-dgx-spark-grace-blackwell-unified-memory-community-solution/358869)
- [NVIDIA Developer Forums: NVTOP with DGX Spark unified memory support](https://forums.developer.nvidia.com/t/nvtop-with-dgx-spark-unified-memory-support/351284)
- [NVIDIA DGX Spark Known Issues — cudaMemGetInfo and SWAP reclamation](https://docs.nvidia.com/dgx/dgx-spark/known-issues.html)
- [HAMi GitHub Issue #1511: Device plugin panics on NVIDIA GB10 — GetMemoryInfo returns "Not Supported"](https://github.com/Project-HAMi/HAMi/issues/1511)
- [nvtop GitHub Issue #426: NVIDIA GB10 Grace Blackwell Reporting Issues — memory N/A](https://github.com/Syllo/nvtop/issues/426)
- [NVIDIA DGX Spark GB10 Unified Memory Architecture — DeepWiki](https://deepwiki.com/NVIDIA/dgx-spark-playbooks/9.1-unified-memory-architecture)
- [Linux kernel manual proc_meminfo(5) — MemAvailable definition](https://man7.org/linux/man-pages/man5/proc_meminfo.5.html)
- [Oracle Linux Blog: Understanding Linux Kernel Memory Statistics — MemAvailable vs MemFree](https://blogs.oracle.com/linux/understanding-linux-kernel-memory-statistics)
- [Red Hat Customer Portal: Interpreting /proc/meminfo — MemFree + Cached is wrong on modern kernels](https://access.redhat.com/solutions/406773)
- [Oracle Linux Blog: Why is MemAvailable sometimes less than MemFree](https://blogs.oracle.com/linux/memavailable-less-than-memfree)
- [PyTorch FAQ: Out of memory errors and reference leaks](https://docs.pytorch.org/docs/stable/notes/faq.html)
- [PyTorch GitHub Issue #27600: Free Memory after CUDA out of memory error](https://github.com/pytorch/pytorch/issues/27600)
- [PyTorch GitHub Issue #82218: OOM during backward leads to memory leaks](https://github.com/pytorch/pytorch/issues/82218)
- [PyTorch Blog: Understanding GPU Memory 2 — Reference Cycles](https://pytorch.org/blog/understanding-gpu-memory-2/)
- [Unsloth Blog: Bug Fixes in LLM Training — Gradient Accumulation denominator bug](https://unsloth.ai/blog/gradient)
- [Crash-safe JSON at scale: atomic writes + recovery without a DB — DEV Community](https://dev.to/constanta/crash-safe-json-at-scale-atomic-writes-recovery-without-a-db-3aic)
- [Claude Code GitHub Issue #29051: claude.json corrupted by concurrent writes — no atomic write](https://github.com/anthropics/claude-code/issues/29051)
- [NVIDIA NVML API Reference Guide — nvmlDeviceGetMemoryInfo](https://docs.nvidia.com/deploy/nvml-api/group__nvmlDeviceQueries.html)
- [NVIDIA XID Errors documentation — Xid 137 and watchdog events](https://docs.nvidia.com/deploy/xid-errors/index.html)
- [Python Speed: Dying fast and slow — out-of-memory crashes in Python — SIGKILL exit codes](https://pythonspeed.com/articles/python-out-of-memory/)
- [nvidia-ml-py PyPI — official NVIDIA Python NVML bindings](https://pypi.org/project/nvidia-ml-py/)
- [pynvml deprecation notice — install nvidia-ml-py instead](https://magazine.ediary.site/blog/pynvml-deprecated-install-nvidia-ml)

---
*Pitfalls research for: GPU telemetry primitives and adaptive training support on DGX Spark GB10 aarch64 (UMA)*
*Researched: 2026-04-01*
