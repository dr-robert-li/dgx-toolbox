---
phase: 2
slug: adapters-and-usage-tracking
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-21
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Inline bash assertions (custom, matching Phase 1 pattern) |
| **Config file** | none — test files are self-contained |
| **Quick run command** | `bash modelstore/test/run-all.sh` |
| **Full suite command** | `bash modelstore/test/run-all.sh` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash modelstore/test/run-all.sh`
- **After every plan wave:** Run `bash modelstore/test/run-all.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 02-01-01 | 01 | 1 | SAFE-01, SAFE-02 | unit | `bash modelstore/test/test-hf-adapter.sh` | ❌ W0 | ⬜ pending |
| 02-01-02 | 01 | 1 | SAFE-01, SAFE-06 | unit | `bash modelstore/test/test-ollama-adapter.sh` | ❌ W0 | ⬜ pending |
| 02-02-01 | 02 | 1 | TRCK-01, TRCK-02 | unit | `bash modelstore/test/test-watcher.sh` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `modelstore/test/test-hf-adapter.sh` — hf_list_models, hf_get_model_path, hf_migrate_model guard behavior (mount check, space check)
- [ ] `modelstore/test/test-ollama-adapter.sh` — ollama_check_server, ollama_list_models, ollama_migrate_model guard behavior (server block)
- [ ] `modelstore/test/test-watcher.sh` — ms_track_usage JSON writes, flock correctness, pidfile lifecycle

*Wave 0 creates test infrastructure alongside implementation.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Docker event parsing for vLLM container | TRCK-02 | Requires running vLLM container | Start vLLM, check usage.json updates |
| inotifywait fires on HF model access | TRCK-02 | Requires real model file access | Run transformers load, check usage.json |
| Ollama server block works on live service | SAFE-06 | Requires running Ollama | With Ollama active, run `modelstore migrate` — should block |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
