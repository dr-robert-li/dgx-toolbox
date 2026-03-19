# Codebase Concerns

**Analysis Date:** 2026-03-19

## Tech Debt

**Docker container lifecycle management:**
- Issue: Multiple scripts use `docker rm -f` to remove containers without checking exit status or logs. This can silently destroy running containers and lose logs if a container exists from a previous failed launch.
- Files: `start-vllm.sh` (line 44), `triton-trtllm.sh` (line 28), `eval-toolbox.sh` (line 18), `data-toolbox.sh` (line 18), `unsloth-studio.sh` (line 16), `unsloth-studio-sync.sh` (line 13), `start-vllm-sync.sh` (line 31)
- Impact: Data loss from containers, difficulty debugging issues, poor UX when restarting services
- Fix approach: Check if container exists and is running before force-removing. Offer user a prompt to confirm, or implement graceful stop-and-remove patterns with status checks.

**Inconsistent error handling in container startup:**
- Issue: Some scripts use `set -e` (exit on error) while others don't. Container healthchecks are inconsistent—some poll with curl, some use sleep loops. No unified pattern for detecting readiness.
- Files: `start-litellm.sh` (set -e missing), `start-open-webui.sh` (set -e present), `unsloth-studio.sh` (complex readiness polling with sleep), `triton-trtllm.sh` (basic startup no health checks)
- Impact: Silent failures are harder to detect. Services may appear started but not be ready. Sync variants don't poll for readiness at all.
- Fix approach: Establish a standard healthcheck function used across all launcher scripts. Document healthcheck endpoints for each service.

**Missing validation for required files and directories:**
- Issue: Scripts assume user has created required files/directories (e.g., `~/.vllm-model`, `~/.litellm/config.yaml`). No checks before use except in `start-vllm.sh` and `setup-litellm-config.sh`.
- Files: `start-vllm.sh` (checks for model), `setup-litellm-config.sh` (creates config if missing), but `triton-trtllm.sh`, `eval-toolbox.sh`, `data-toolbox.sh` assume directories exist
- Impact: Scripts may fail silently or with cryptic Docker errors if mount paths don't exist
- Fix approach: Add `mkdir -p` calls before all volume mounts in Docker run commands. Validate config files exist before use.

**Hard-coded DuckDB version in Dockerfile:**
- Issue: `data-toolbox/Dockerfile` pins DuckDB to v1.2.2 (line 23). This version becomes outdated and creates maintenance burden.
- Files: `data-toolbox/Dockerfile` (line 23)
- Impact: Security updates for DuckDB won't be picked up automatically. Package will become stale.
- Fix approach: Use a version constraint (e.g., `v1.2.*`) or fetch latest compatible release dynamically.

**Environment variable loading without validation:**
- Issue: `start-litellm.sh` uses `--env-file` with a fallback that silently omits the flag if file doesn't exist (line 66-77). This creates two different execution paths that may behave unpredictably.
- Files: `start-litellm.sh` (lines 66-77)
- Impact: If `.env` file exists but is malformed, Docker will fail. If it doesn't exist, no error—silent continuation may hide configuration issues.
- Fix approach: Validate `.env` file syntax before passing to Docker. Provide clear error messages if required variables are missing.

**Unsloth Studio dependency resolution logic is fragile:**
- Issue: Complex Python script in `unsloth-studio.sh` (lines 42-69) parses package metadata, resolves dependencies, and installs them in two passes. This is fragile and version-dependent.
- Files: `unsloth-studio.sh` (lines 42-69), `unsloth-studio-sync.sh` (lines 24-52)
- Impact: Dependency resolution can break if upstream packages change their metadata format. torchcodec is uninstalled twice for unclear reasons.
- Fix approach: Replace with simpler approach—use `pip install --no-deps unsloth` followed by explicit dependency specification. Document why torchcodec needs to be removed.

## Known Bugs

**vLLM container doesn't validate model existence before starting:**
- Symptoms: Container starts but fails silently during model loading if the model doesn't exist locally and network fetch fails
- Files: `start-vllm.sh` (lines 47-59), `start-vllm-sync.sh` (lines 33-45)
- Trigger: Run `start-vllm.sh` with a non-existent model or when HF cache is on a slow network
- Workaround: Check logs with `docker logs vllm` to see actual error

**LiteLLM config generator doesn't handle missing .env file gracefully:**
- Symptoms: Docker start fails if `~/.litellm/.env` doesn't exist but is referenced in `--env-file`
- Files: `start-litellm.sh` (line 66)
- Trigger: Run `start-litellm.sh` before running `setup-litellm-config.sh`
- Workaround: Create empty file first: `touch ~/.litellm/.env`

**Triton TRT-LLM stays in sleep loop if model_repo is empty:**
- Symptoms: Server starts but does nothing—useful for setting up model repos, but unclear if intentional
- Files: `triton-trtllm.sh` (lines 43-48)
- Trigger: Start Triton without populating `~/triton/model_repo`
- Workaround: This is documented as expected behavior in README, but the "sleep infinity" pattern is fragile—container appears running but is idle

**Ollama-remote script requires sudo but no sudo check:**
- Symptoms: Script fails at runtime if user is not sudoer
- Files: `setup-ollama-remote.sh` (uses `sudo systemctl`)
- Trigger: Run as non-privileged user
- Workaround: Ensure user is in docker group or can use sudo

## Security Considerations

**API keys stored in plain text in shell scripts:**
- Risk: `setup-litellm-config.sh` prompts for API keys and writes them to `~/.litellm/.env` with `chmod 600`. Keys are visible in shell history during interactive prompt.
- Files: `setup-litellm-config.sh` (lines 74-86)
- Current mitigation: File permissions set to 600 (user-only readable)
- Recommendations: Use `read -s` for silent input; consider using a credentials manager or systemd secret variables. Document secure handling in README.

**Docker containers run with `--gpus all` without resource limits:**
- Risk: Any container can consume all GPU memory, causing resource starvation
- Files: All launcher scripts (e.g., `start-vllm.sh` line 49, `unsloth-studio.sh` line 34)
- Current mitigation: `--restart unless-stopped` prevents cascading restarts, but doesn't limit resources
- Recommendations: Add `--memory` and GPU memory limits if feasible. Document resource requirements per service.

**Unsloth Studio downloads and installs packages without hash verification:**
- Risk: Dependency resolution via `pip install` without version pinning or hash checking in the Dockerfile
- Files: `unsloth-studio.sh` (line 42), `unsloth-studio-sync.sh` (line 25)
- Current mitigation: Uses official NGC base image from NVIDIA
- Recommendations: Pin specific versions of critical packages. Add `--require-hashes` to pip install if feasible.

**DuckDB binary downloaded without checksum verification:**
- Risk: `data-toolbox/Dockerfile` fetches DuckDB from GitHub without verifying checksum
- Files: `data-toolbox/Dockerfile` (line 23)
- Current mitigation: Uses HTTPS and official GitHub release
- Recommendations: Add SHA256 checksum verification after download before using the binary.

**Host directories mounted with read-write to containers without audit:**
- Risk: Containers have access to `~/.cache/huggingface`, `~/data/`, `~/eval/` with full permissions
- Files: All Dockerfile-based scripts (e.g., `eval-toolbox.sh` line 23-27)
- Current mitigation: Containers run as root but within Docker namespace
- Recommendations: Consider explicit mount permissions (`:ro` for read-only where appropriate). Document data access policies.

## Performance Bottlenecks

**Unsloth Studio has 30-minute initialization overhead:**
- Problem: First launch installs dependencies, resolves conflicts, uninstalls/reinstalls torchcodec. Takes up to 30 minutes.
- Files: `unsloth-studio.sh` (lines 42-69), `unsloth-studio-sync.sh` (lines 24-52)
- Cause: Complex multi-step dependency resolution logic. No pre-baked image with dependencies.
- Improvement path: Build and push a pre-configured Unsloth Studio image with all dependencies included. Cache the image locally.

**DuckDB binary downloaded on every data-toolbox build:**
- Problem: `data-toolbox/Dockerfile` fetches DuckDB from GitHub during build (line 23)
- Files: `data-toolbox/Dockerfile` (line 23)
- Cause: No Docker layer caching for binary downloads
- Improvement path: Use a base image with DuckDB pre-installed, or use apt-get installation if available for aarch64.

**vLLM model loading blocks startup logs:**
- Problem: `start-vllm.sh` streams logs with `docker logs -f`, but model loading can take minutes—user sees no output during download
- Files: `start-vllm.sh` (line 78)
- Cause: Docker logs only show messages after container initialization
- Improvement path: Add a readiness check that monitors both logs and API endpoint (like Unsloth does).

**Triton TRT-LLM waits indefinitely with no progress indicator:**
- Problem: If `model_repo` is empty, container sleeps forever with no user feedback
- Files: `triton-trtllm.sh` (line 47)
- Cause: `sleep infinity` with no logs or status messages
- Improvement path: Add periodic status messages or a watchdog that checks `model_repo` periodically and exits if nothing happens after timeout.

## Fragile Areas

**Container name collisions across scripts:**
- Files: All launcher scripts use fixed container names (`vllm`, `litellm`, `open-webui`, etc.)
- Why fragile: If you run `start-vllm.sh` twice simultaneously, the second invocation fails. Force-remove pattern is unsafe.
- Safe modification: Add a timestamp or unique ID to container names. Check for running containers before creating new ones.
- Test coverage: No integration tests verifying concurrent startup scenarios.

**Sync variants vs. interactive variants have duplicated logic:**
- Files: `start-vllm.sh` vs. `start-vllm-sync.sh`, `unsloth-studio.sh` vs. `unsloth-studio-sync.sh`, etc.
- Why fragile: Changes to one variant may not propagate to the other. Inconsistencies can appear.
- Safe modification: Extract common logic into shared functions or a library. Use feature flags or parameters to control sync behavior.
- Test coverage: No tests verifying sync and interactive variants behave identically up to the fork point.

**Path assumptions in mounts and directories:**
- Files: All scripts assume `$HOME` is writable and has specific subdirectories (`~/data/`, `~/eval/`, `~/.cache/huggingface`, etc.)
- Why fragile: Mounts break if directories are symlinks, on different filesystems, or lack permissions
- Safe modification: Add symlink resolution with `readlink -f`. Validate mount paths are accessible before use.
- Test coverage: No tests for non-standard home directory configurations.

**Dockerfile package installations without explicit version constraints:**
- Files: `data-toolbox/Dockerfile`, `eval-toolbox/Dockerfile`
- Why fragile: `pip install pandas` without a version can pick up breaking changes. No `requirements.txt` lock file.
- Safe modification: Use `requirements.txt` with pinned versions and hashes. Regenerate lock files regularly.
- Test coverage: No build reproducibility tests.

**LiteLLM config generator assumes service auto-detection via curl/docker commands:**
- Files: `setup-litellm-config.sh` (lines 22-62)
- Why fragile: Ollama detection via `curl http://localhost:11434/api/version` fails silently if Ollama is not running. vLLM detection via `docker ps` fails if Docker daemon is unavailable.
- Safe modification: Add explicit error messages for each detection failure. Provide manual configuration fallback.
- Test coverage: No tests for scenarios where services are running on non-default ports or hosts.

## Scaling Limits

**Single GPU shared across multiple containers:**
- Current capacity: All inference servers (vLLM, Triton, Ollama) and tools (Unsloth, eval-toolbox, data-toolbox) can run on the same GPU
- Limit: GPU memory is not partitioned—if vLLM loads a large model, other containers may OOM
- Scaling path: Implement GPU partitioning with `nvidia-smi mig` (for MI300x-compatible GPUs). Document per-service GPU requirements.

**Ollama single-process limit:**
- Current capacity: Ollama runs as a systemd service on the host
- Limit: Cannot easily run multiple Ollama instances or separate them by model
- Scaling path: Containerize Ollama with resource isolation. Support multiple Ollama containers with different models.

**Docker socket access for all containers:**
- Current capacity: Containers can mount `/var/run/docker.sock` or access host Docker daemon
- Limit: No container isolation—a compromised container can control other containers
- Scaling path: Consider rootless Docker or user namespaces. Implement least-privilege socket access.

## Dependencies at Risk

**NGC PyTorch base image versioning:**
- Risk: `data-toolbox/Dockerfile` and `eval-toolbox/Dockerfile` use `FROM nvcr.io/nvidia/pytorch:26.02-py3` with a specific date tag
- Impact: If NVIDIA stops hosting this tag, builds fail. No fallback or version negotiation.
- Migration plan: Pin a full image digest (SHA) instead of a tag. Maintain a cache of critical base images. Test monthly for availability.

**Unsloth dependency on torchcodec uninstall:**
- Risk: Explicit uninstall of `torchcodec` (lines 66, 68 in unsloth-studio.sh) suggests version conflict
- Impact: If torchcodec becomes a required dependency in a future Unsloth version, this workaround breaks
- Migration plan: Track Unsloth releases for torchcodec integration. Test regularly. Document the reason for the uninstall.

**LiteLLM package version pinning missing:**
- Risk: `start-litellm.sh` uses `ghcr.io/berriai/litellm:main-latest` (line 8)—the `main-latest` tag is unstable
- Impact: New versions may introduce breaking API changes
- Migration plan: Migrate to a stable release tag (e.g., `v1.0.0`). Implement CI tests for LiteLLM compatibility.

**vLLM model compatibility:**
- Risk: `start-vllm.sh` and README recommend specific models (Llama-3.1, Nemotron) but no version pinning
- Impact: Model variants may have different API signatures or license requirements
- Migration plan: Maintain a tested models list with specific HF model IDs and versions. Test quarterly.

## Missing Critical Features

**No unified logging or log aggregation:**
- Problem: Each service logs independently to Docker. No centralized view of all logs.
- Blocks: Debugging multi-service issues requires opening multiple log streams
- Solution: Implement a Docker logging driver that forwards logs to a central location (syslog, journald, or ELK stack). Document logging architecture.

**No service dependency orchestration:**
- Problem: User must manually start services in correct order (Ollama before LiteLLM, vLLM before Open-WebUI)
- Blocks: Complex multi-service workflows require manual coordination
- Solution: Implement a startup orchestrator (e.g., `docker-compose`) that declares dependencies and starts services in order.

**No health checks or monitoring:**
- Problem: No built-in way to verify all services are healthy or to restart failed containers
- Blocks: Long-running setups may have silent service failures
- Solution: Implement health check endpoints for all services. Use Docker health checks or a monitoring agent (Prometheus + Grafana).

**No backup or persistence management:**
- Problem: Data in `~/data/`, models, and configuration are not backed up
- Blocks: Data loss if disk fails or user accidentally deletes directories
- Solution: Document backup procedures. Implement automated snapshots or incremental backups.

## Test Coverage Gaps

**No integration tests for container startup:**
- What's not tested: Verify that `start-vllm.sh` successfully starts vLLM, loads a model, and serves requests
- Files: `start-vllm.sh`, `start-vllm-sync.sh`, `start-litellm.sh`, etc.
- Risk: Silent failures in launcher scripts not caught until production use
- Priority: High

**No tests for concurrent service startup:**
- What's not tested: Starting multiple services simultaneously (e.g., vLLM and Triton) and verifying no port/resource conflicts
- Files: All launcher scripts
- Risk: Race conditions and resource conflicts not detected
- Priority: Medium

**No validation tests for Docker Dockerfile builds:**
- What's not tested: Build reproducibility, layer caching, security scanning, size verification
- Files: `data-toolbox/Dockerfile`, `eval-toolbox/Dockerfile`
- Risk: Build failures in CI or on user machines with different Docker versions
- Priority: High

**No tests for configuration generation:**
- What's not tested: `setup-litellm-config.sh` generates valid YAML. Edge cases: missing services, malformed API keys, unusual model names
- Files: `setup-litellm-config.sh`
- Risk: Generated configs may be invalid or incomplete
- Priority: Medium

**No tests for script idempotency:**
- What's not tested: Running `dgx-global-base-setup.sh` twice is safe. Running launcher scripts twice is safe.
- Files: `dgx-global-base-setup.sh`, all launcher scripts
- Risk: Second invocation may fail or behave differently
- Priority: Medium

**No tests for edge cases:**
- What's not tested: User home directory with spaces or special characters. Missing HF cache. Disk full. Out of GPU memory.
- Files: All scripts
- Risk: Scripts fail cryptically in corner cases
- Priority: Low

---

*Concerns audit: 2026-03-19*
