---
phase: 13
slug: gpu-telemetry-primitives
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-01
---

# Phase 13 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | pytest 9.0.2 |
| **Config file** | `telemetry/pyproject.toml` [tool.pytest.ini_options] |
| **Quick run command** | `cd dgx-toolbox/telemetry && pytest tests/ -x -q` |
| **Full suite command** | `cd dgx-toolbox/telemetry && pytest tests/ -v` |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run `cd dgx-toolbox/telemetry && pytest tests/ -x -q`
- **After every plan wave:** Run `cd dgx-toolbox/telemetry && pytest tests/ -v`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 13-01-01 | 01 | 1 | TELEM-13,14 | unit | `pytest tests/test_failure_classifier.py -x` | ❌ W0 | ⬜ pending |
| 13-01-02 | 01 | 1 | TELEM-01,02,04 | unit | `pytest tests/test_sampler.py -x` | ❌ W0 | ⬜ pending |
| 13-01-03 | 01 | 1 | TELEM-03 | unit | `pytest tests/test_sampler.py::test_append_jsonl -x` | ❌ W0 | ⬜ pending |
| 13-02-01 | 02 | 2 | TELEM-05,06 | unit | `pytest tests/test_uma_model.py -x` | ❌ W0 | ⬜ pending |
| 13-02-02 | 02 | 2 | TELEM-07,08 | unit | `pytest tests/test_effective_scale.py -x` | ❌ W0 | ⬜ pending |
| 13-02-03 | 02 | 2 | TELEM-09,10 | unit | `pytest tests/test_anchor_store.py -x` | ❌ W0 | ⬜ pending |
| 13-02-04 | 02 | 2 | TELEM-11,12 | unit | `pytest tests/test_probe.py -x` | ❌ W0 | ⬜ pending |
| 13-03-01 | 03 | 3 | TELEM-15 | smoke | `pip install -e dgx-toolbox/telemetry/ && python -c "from telemetry.sampler import GPUSampler"` | ❌ W0 | ⬜ pending |
| 13-03-02 | 03 | 3 | TELEM-16 | unit | `pytest tests/test_dgx_toolbox_bridge.py -x` | ❌ W0 | ⬜ pending |
| 13-03-03 | 03 | 3 | TELEM-17 | smoke | `bash status.sh` | ❌ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `telemetry/tests/conftest.py` — shared fixtures: mock pynvml module, tmp_path anchor store
- [ ] `telemetry/tests/test_sampler.py` — covers TELEM-01..04
- [ ] `telemetry/tests/test_uma_model.py` — covers TELEM-05..06
- [ ] `telemetry/tests/test_effective_scale.py` — covers TELEM-07..08
- [ ] `telemetry/tests/test_anchor_store.py` — covers TELEM-09..10
- [ ] `telemetry/tests/test_probe.py` — covers TELEM-11..12
- [ ] `telemetry/tests/test_failure_classifier.py` — covers TELEM-13..14
- [ ] `telemetry/tests/test_dgx_toolbox_bridge.py` — covers TELEM-16
- [ ] `telemetry/pyproject.toml` — package definition with pytest config

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| status.sh GPU TELEMETRY block | TELEM-17 | Bash output formatting; requires visual inspection | Run `bash status.sh` and verify GPU TELEMETRY section appears or "sampler not installed" |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
