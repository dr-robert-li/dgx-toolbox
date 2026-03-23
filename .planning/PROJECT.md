# Model Store — Tiered Storage for DGX Spark

## What This Is

A tiered model storage system for NVIDIA DGX Spark that automatically manages ML model lifecycle between a fast internal NVMe ("hot" store) and an external drive ("cold" store). Models land on the hot store when downloaded, get migrated to cold storage after a configurable retention period (default 14 days of inactivity), and are recalled transparently when needed. Provides a single CLI (`modelstore`) plus individual scripts for cron and launcher integration.

## Core Value

Models are always accessible regardless of which tier they're on — symlinks ensure transparent access — while the hot drive never fills up with stale models.

## Requirements

### Validated

- ✓ External drive formatted and mounted (`/media/robert_li/modelstore-1tb`, ext4, `nofail` fstab) — existing
- ✓ HuggingFace cache at `~/.cache/huggingface/hub/` — existing
- ✓ Ollama models at `~/.ollama/models/` — existing
- ✓ Launcher scripts for vLLM, eval-toolbox, data-toolbox, Unsloth, Ollama — existing
- ✓ Cron available on host — existing
- ✓ GNOME desktop environment for `notify-send` — existing

### Active

#### v1.0 Phase 4 (completing separately)

- [ ] Single CLI entry point (`modelstore`) dispatching to subcommands
- [ ] `modelstore status` — tier view with sizes, timestamps, space
- [ ] `modelstore revert` — undo all tiering, remove symlinks
- [ ] Individual scripts for cron and Sync integration
- [ ] README, CHANGELOG, .gitignore updates

#### v1.1 Safety Harness

- [ ] Gateway service (FastAPI) with POST /chat orchestrating the full safety pipeline
- [ ] Pluggable model adapters via LiteLLM (optional — harness can be bypassed)
- [ ] Auth, rate limiting, and per-tenant policy enforcement at ingress
- [ ] Pre-model guardrails via NeMo Guardrails: content filters, prompt injection, PII/secrets detection
- [ ] Post-model guardrails: toxicity, bias, PII leakage, jailbreak-success detection
- [ ] Constitutional AI-style self-critique with configurable judge model (default same-model, swappable)
- [ ] User-editable constitutional AI principles (review, customize, tune the constitution)
- [ ] User-tunable pre/post guardrail rules: review, customize thresholds, enable/disable individual checks
- [ ] Judge model provides guided suggestions for guardrail and constitution tuning (optional)
- [ ] Refusal calibration: helpful refusal, soft steering, threshold tuning
- [ ] Streaming guardrails: evaluate every N tokens and at end of stream with redaction
- [ ] Full trace logging (prompt, tools, model outputs, guardrail decisions)
- [ ] Custom replay eval harness for safety/refusal metrics against POST /chat
- [ ] lm-eval-harness integration for general capability benchmarks
- [ ] CI/CD eval integration: block promotion if safety metrics regress
- [ ] Distributed live red teaming: adversarial prompt generation from past critiques/evals/logs
- [ ] Human-in-the-loop review dashboard for eval steering and correction (optional)
- [ ] Feedback loop: corrections feed into threshold calibration and fine-tuning data

### Out of Scope

- RAID or multi-drive pooling — this is two-tier only (hot + cold)
- Automatic model downloading/pulling — only manages storage of already-downloaded models
- Cloud storage tiering (S3, GCS) — local drives only
- Per-model pinning (always keep on hot) — all models follow the same retention policy
- Fine-tuning orchestration — harness feeds data for fine-tuning but doesn't run training jobs
- Model hosting/serving — LiteLLM and vLLM handle that; harness is a safety layer only
- Web UI for policy editing — policies are code/config, not a CMS

## Current Milestone: v1.2 Autoresearch Integration

**Goal:** End-to-end data → training → inferencing pipeline connecting Karpathy autoresearch to local data sources and models on DGX Spark, with safety harness evals after each training experiment, and the resulting model available for inference behind the harness.

**Target features:**
- Config + glue scripts connecting autoresearch to local datasets (~/data/) and HF cache models
- Post-training safety eval hook: after each autoresearch experiment, run harness replay evals on the checkpoint
- Model registration: trained checkpoints automatically registered in LiteLLM/vLLM for inference behind the safety harness
- Runnable demo script showing the full pipeline with a small sample dataset
- Step-by-step documentation walkthrough

## Context

- DGX Spark has a 3.7TB internal NVMe (system drive) and a 953.9GB external NVMe mounted at `/media/robert_li/modelstore-1tb`
- The 238.5GB external drive at `/media/robert_li/backup-256g` (exFAT) is a backup drive, not part of tiering
- Two model ecosystems: HuggingFace cache (file-based, symlink-friendly) and Ollama (blob-based, also symlink-friendly)
- All model consumers (vLLM, transformers, Ollama) resolve through symlinks transparently
- Existing `lib.sh` provides shared functions for DGX Toolbox scripts
- Desktop notifications via `notify-send` work on the GNOME session
- LiteLLM proxy already running as model router (Ollama, vLLM, cloud APIs)
- Safety harness sits optionally in front of LiteLLM — can be bypassed for direct model access
- Python is available on host and in containers; harness is the first Python component in this repo

## Constraints

- **Architecture**: aarch64 (ARM64) — all tools must be compatible
- **Symlink safety**: Must verify cold drive is mounted before creating symlinks; broken symlinks = model load failures
- **Non-destructive**: Init and revert must never delete model data — only move it
- **Bash only**: No Python dependencies for the core modelstore scripts (they run outside containers)
- **NVIDIA Sync compatible**: Scripts must work when invoked remotely via Sync (no TTY required for cron/migration)

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Symlinks over hard links | Symlinks work across filesystems (internal NVMe ↔ external NVMe) | — Pending |
| Configurable hot/cold at init | User may swap drives or add new ones later; reinit with migration handles this | — Pending |
| `notify-send` for disk warnings | DGX Spark runs GNOME; desktop notifications are the most visible alert | — Pending |
| Single `modelstore` CLI + individual scripts | CLI for interactive use, individual scripts for cron/hooks/Sync | — Pending |
| Bash only (no Python) | Core scripts run on host, not in containers; minimize dependencies | — Pending |

---
*Last updated: 2026-03-24 after v1.2 Autoresearch Integration milestone start*
