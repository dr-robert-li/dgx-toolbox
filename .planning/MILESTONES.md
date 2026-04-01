# Milestones

## v1.0 — Model Store (Complete: 2026-03-21)

Tiered model storage for DGX Spark. Automatic migration of stale models from hot NVMe to cold external drive, transparent recall via symlinks, usage tracking, CLI, and cron automation.

**Phases:** 1–4 | **Plans:** 8 | **Requirements:** INIT-01–08, MIGR-01–08, RECL-01–03, TRCK-01–02, SAFE-01–06, CLI-01–07, DOCS-01–04

## v1.1 — Safety Harness (Complete: 2026-03-23)

Model-agnostic safety layer wrapping any open-source model with guardrails, constitutional AI critique, evals, red teaming, and human-in-the-loop feedback.

**Phases:** 5–10 | **Plans:** 16 | **Requirements:** GATE-01–05, TRAC-01–04, INRL-01–05, OURL-01–04, REFU-01–04, CSTL-01–05, EVAL-01–04, RDTM-01–04, HITL-01–04

## v1.2 — Autoresearch Integration (Complete: 2026-03-24)

End-to-end data → training → inferencing pipeline connecting Karpathy autoresearch to local data sources and models on DGX Spark, with safety harness evals after each training experiment.

**Phases:** 11–12 | **Plans:** 3 | **Requirements:** DATA-01–03, TRSF-01–03, MREG-01–03, DEMO-01–02
