# Codebase Concerns

**Analysis Date:** 2026-04-01

## Security Concerns

**All services bind to 0.0.0.0 (network-wide exposure):**
- Issue: Every container launcher binds ports to `0.0.0.0`, exposing services to the entire LAN without authentication.
- Files: `inference/start-vllm.sh:51`, `inference/start-litellm.sh:64`, `docker-compose.inference.yml:18,39,54`, `docker-compose.data.yml:14,23`, `eval/triton-trtllm.sh:36-38`, `eval/eval-toolbox-jupyter.sh:20`
- Impact: LiteLLM, vLLM, Open-WebUI, Label Studio, Argilla, Triton, and Jupyter are all accessible from any machine on the network. Jupyter is launched with empty token and password (`--NotebookApp.token='' --NotebookApp.password=''` in `eval/eval-toolbox-jupyter.sh:28`).
- Recommendations: Bind to `127.0.0.1` by default unless `--lan` flag is passed. Remove the empty token/password from Jupyter launcher.

**Harness guardrails fail-open by design:**
- Issue: When NeMo Guardrails is unavailable or throws any exception, all NeMo-backed rails silently return score 0.0 (pass). The critique engine also fails open on any exception.
- Files: `harness/guards/engine.py:339-341` (`except Exception: return 0.0`), `harness/critique/engine.py:143-144` (`except (asyncio.TimeoutError, Exception): return None`)
- Impact: A misconfigured or crashed NeMo service causes all safety rails to silently stop functioning. No logging or alerting occurs on NeMo failure. Only regex-based injection detection continues to work.
- Recommendations: Log a warning on NeMo failure. Track and surface "nemo_unavailable" status in admin endpoints. Consider a configurable fail-closed mode for high-risk deployments.

**Hardcoded fallback model name routes data to external API:**
- Issue: When the deepteam red team dispatch cannot resolve a judge model, it falls back to `"gpt-3.5-turbo"`, which assumes a cloud API key is configured and routes adversarial prompts to an external service.
- Files: `harness/redteam/router.py:147-149`
- Impact: Red team prompts containing sensitive near-miss data could be sent to OpenAI if local model resolution fails.
- Recommendations: Default to a local model name (e.g., `"llama3.1"`) or refuse to run deepteam jobs when no judge model is explicitly configured.

**Auth brute-force vulnerability:**
- Issue: `verify_api_key` iterates through all tenants running argon2 verify on each, with no rate limiting on auth failures and no lockout mechanism.
- Files: `harness/auth/bearer.py:22-29`
- Impact: An attacker can brute-force API keys without throttling. Argon2 is intentionally slow (which helps), but there is no logging of failed auth attempts and no IP-based rate limiting.
- Recommendations: Log failed auth attempts. Consider adding per-IP rate limiting on 401 responses.

**Broad exception swallowing in adversarial variant generation:**
- Issue: `generate_adversarial_variants` catches all exceptions including bare `Exception` and returns empty list with no logging.
- Files: `harness/redteam/engine.py:58`
- Impact: Failures in red team variant generation are completely silent, making debugging impossible.
- Recommendations: Log the exception before returning empty list.

**Dockerfiles run as root:**
- Issue: All three Dockerfiles do not create or switch to a non-root user.
- Files: `base-toolbox/Dockerfile`, `eval-toolbox/Dockerfile`, `data-toolbox/Dockerfile`
- Impact: Containers run all operations as root. With volume mounts to host directories (`~/data`, `~/eval`), a container escape or malicious package could modify host files as root.
- Recommendations: Add a non-root USER in Dockerfiles, at least for production use. Lower priority for single-tenant DGX workstation.

**Hardcoded API key placeholder in scripts:**
- Issue: `scripts/demo-autoresearch.sh:174` and `scripts/screen-data.sh:82` use `sk-devteam-test` as a default Bearer token.
- Files: `scripts/demo-autoresearch.sh:174`, `scripts/screen-data.sh:82`
- Impact: If the harness tenant config uses this key in production, it becomes a known default credential.
- Recommendations: Remove fallback defaults; always require explicit key configuration.

**DuckDB binary downloaded without checksum verification:**
- Risk: `data-toolbox/Dockerfile` fetches DuckDB from GitHub without verifying checksum.
- Files: `data-toolbox/Dockerfile:14-19`
- Current mitigation: Uses HTTPS and official GitHub release.
- Recommendations: Add SHA256 checksum verification after download before using the binary.

## Technical Debt

**SQLite connection-per-operation pattern:**
- Issue: `TraceStore` opens a new `aiosqlite.connect()` for every single database operation rather than maintaining a persistent connection.
- Files: `harness/traces/store.py:117`, `harness/traces/store.py:149`, `harness/traces/store.py:164`, `harness/traces/store.py:194` (and every other method)
- Impact: Under high request volume, this creates excessive filesystem I/O and connection overhead. SQLite WAL mode mitigates some contention, but connection churn is unnecessary.
- Fix approach: Hold a single persistent `aiosqlite` connection initialized in `init_db()` and reuse it across operations. Use a lock for write serialization.

**Duplicate `_extract_triggering_rail` implementations:**
- Issue: The same function logic exists in three places with slightly different implementations.
- Files: `harness/traces/store.py:47-70` (`_extract_triggering_rail`), `harness/hitl/ui.py:15-35` (`_extract_triggering_rail_inline`), inline logic in `harness/hitl/calibrate.py`
- Impact: Bug fixes or behavior changes must be applied in multiple places. The UI version explicitly notes it "mirrors" the store version.
- Fix approach: Extract to a shared utility module (e.g., `harness/guards/utils.py`) and import from all three locations.

**Unpinned Docker image tags:**
- Issue: All Docker images use `latest` or rolling tags without version pinning.
- Files: `inference/start-vllm.sh:4` (`vllm/vllm-openai:latest`), `inference/start-litellm.sh:4` (`ghcr.io/berriai/litellm:main-latest`), `docker-compose.inference.yml:15,36,51`
- Impact: Builds and deployments are not reproducible. A breaking upstream change to vLLM or LiteLLM could silently break the toolbox. The base-toolbox Dockerfile pins `nvcr.io/nvidia/pytorch:26.02-py3`, which is good, but downstream images reference `base-toolbox:latest`.
- Fix approach: Pin all external images to specific version tags or digests.

**Unpinned pip dependencies in Dockerfiles:**
- Issue: All `pip install` commands in Dockerfiles install packages without version constraints (e.g., `pip install "datasets" "pandas" "scikit-learn"`).
- Files: `base-toolbox/Dockerfile:18-28`, `eval-toolbox/Dockerfile:4-12`, `data-toolbox/Dockerfile:22-69`
- Impact: Builds are not reproducible. Dependency resolution can change between builds.
- Fix approach: Generate and commit a `requirements.txt` with pinned versions for each Dockerfile.

**In-memory rate limiter (not persistent or distributed):**
- Issue: `SlidingWindowLimiter` is purely in-memory with a single asyncio lock. Rate limit state is lost on process restart.
- Files: `harness/ratelimit/sliding_window.py`
- Impact: A restart resets all rate limits. For a single-node DGX workstation this is acceptable, but limits horizontal scaling.
- Fix approach: For multi-instance deployments, use Redis-backed rate limiting. For single-instance, document the limitation.

**Hardcoded model name in NeMo LLMRails initialization:**
- Issue: `create_guardrail_engine` hardcodes `model_name="llama3.1"` when initializing the LangChain ChatOpenAI LLM for NeMo.
- Files: `harness/guards/engine.py:492`
- Impact: If the local LLM model name changes, NeMo guardrails break silently (fail-open, so no error visible).
- Fix approach: Make the NeMo LLM model name configurable via environment variable or rails.yaml config.

**Sync and interactive script variants have duplicated logic:**
- Issue: Each launcher has a sync variant (e.g., `start-vllm.sh` vs `start-vllm-sync.sh`) with duplicated Docker run commands.
- Files: `inference/start-vllm.sh` vs `inference/start-vllm-sync.sh`, `inference/start-litellm.sh` vs `inference/start-litellm-sync.sh`, `inference/start-open-webui.sh` vs `inference/start-open-webui-sync.sh`
- Impact: Changes to one variant may not propagate to the other. Inconsistencies can appear.
- Fix approach: Extract common logic into shared functions in `lib.sh`. Use a parameter or environment variable to control sync behavior.

**Docker container lifecycle uses `docker rm -f` without checks:**
- Issue: Multiple scripts use `docker rm -f` to remove containers without checking exit status or logs.
- Files: `inference/start-vllm.sh:44`, `eval/triton-trtllm.sh:28`
- Impact: Running containers are silently destroyed, potentially losing logs or in-progress work.
- Fix approach: Check if container exists and is running before force-removing. Use the `ensure_container` pattern from `lib.sh`.

## Performance Concerns

**Query-all-then-filter pattern in HITL queue:**
- Issue: `query_hitl_queue` fetches up to `limit` rows from SQLite, then applies rail_filter and hide_reviewed filters in Python.
- Files: `harness/traces/store.py:400-488`
- Impact: The SQL query may return hundreds of rows that are then discarded by Python filters. The actual returned result set could be much smaller than the SQL LIMIT, leading to incomplete pages.
- Fix approach: Push rail_filter into the SQL WHERE clause. For hide_reviewed, add `AND c.action IS NULL` to the SQL.

**Sequential red team variant generation:**
- Issue: `run_deepteam_job` processes near-miss traces sequentially, making one LLM call per trace.
- Files: `harness/redteam/engine.py:103-117`
- Impact: With 100 near-miss traces and 3 variants each, this means 100 sequential HTTP calls, potentially taking 10+ minutes.
- Fix approach: Use `asyncio.gather` with a concurrency limiter (semaphore) to parallelize variant generation.

**Blocking PII analysis at import time:**
- Issue: `AnalyzerEngine()` is instantiated at module import time, loading the spaCy NER model synchronously (several seconds).
- Files: `harness/pii/redactor.py:18`
- Impact: First import of the redactor module blocks for seconds. The harness startup handles this via eager import (`harness/main.py:47`), but any test or script that imports the redactor pays this cost.
- Fix approach: Use lazy initialization. Low priority since startup already handles this.

**HITL UI fetches full queue to look up single item:**
- Issue: `_fetch_item_by_id` fetches the full HITL queue (last 30 days) to find a single item by request_id.
- Files: `harness/hitl/ui.py:136-149`
- Impact: Each row selection in the Gradio dashboard triggers an expensive full-queue fetch.
- Fix approach: Add a dedicated `/admin/hitl/trace/{request_id}` endpoint that queries by primary key.

## Reliability Concerns

**No health check endpoint:**
- Issue: The harness FastAPI app has no `/health` or `/ready` endpoint for container orchestration health checks.
- Files: `harness/main.py`
- Impact: Docker HEALTHCHECK, Kubernetes probes, and monitoring tools cannot verify the harness is operational. The `/probe` endpoint requires auth.
- Fix approach: Add an unauthenticated `GET /health` endpoint that returns 200 when the app is ready.

**No graceful shutdown of background tasks:**
- Issue: The `_run_job` background task for red team jobs is started via `asyncio.create_task` but is not cancelled during app shutdown.
- Files: `harness/redteam/router.py:58-59`, `harness/main.py:77-79` (lifespan only closes http_client)
- Impact: If the app shuts down during a long-running garak scan, the task may be orphaned. The garak subprocess (`harness/redteam/garak_runner.py:48`) may continue running.
- Fix approach: Cancel `redteam_active_task` in the lifespan teardown. Send SIGTERM to garak subprocess on cancellation.

**No retry logic for trace writes:**
- Issue: The `_write_trace` background task in the proxy has no error handling. If the SQLite write fails, the trace data is silently lost.
- Files: `harness/proxy/litellm.py:236-296`
- Impact: Under disk pressure or SQLite lock contention, trace records can be dropped without any indication.
- Fix approach: Wrap the write in try/except with logging. Consider a simple retry with backoff.

**Cold drive mount check is non-recoverable:**
- Issue: `check_cold_mounted` calls `ms_die` (exit 1) if the cold drive is not mounted, with no retry or fallback.
- Files: `modelstore/lib/common.sh:30-33`, `modelstore/cmd/migrate.sh:260`
- Impact: Cron-triggered migrations fail silently if cold drive is temporarily unmounted (e.g., NFS hiccup). No retry on next cron tick because the cron job runs the full script.
- Fix approach: Add retry logic or graceful skip-and-log when cold drive is temporarily unavailable.

## Maintenance Concerns

**Large proxy endpoint function (233 lines):**
- Issue: `chat_completions` in `harness/proxy/litellm.py` handles auth, rate limiting, guardrails, proxying, critique loop, PII redaction, and tracing in a single function.
- Files: `harness/proxy/litellm.py:27-233`
- Impact: Difficult to test individual pipeline stages in isolation. Each new feature adds more code to this function.
- Fix approach: Extract pipeline stages into separate async functions or a middleware chain. The function already has numbered comments delineating stages, making extraction straightforward.

**Shell test suite is not integrated with CI:**
- Issue: The modelstore shell tests (`modelstore/test/run-all.sh`) and integration tests (`scripts/test-data-integration.sh`, `scripts/test-eval-register.sh`) exist but the CI workflow only runs ShellCheck, bash syntax checks, and Python harness tests.
- Files: `.github/workflows/test.yml`, `modelstore/test/run-all.sh`, `scripts/test-data-integration.sh`, `scripts/test-eval-register.sh`
- Impact: Modelstore regressions and integration regressions are not caught in CI.
- Fix approach: Add a CI job that runs `modelstore/test/run-all.sh` in a container with mock filesystems.

**No API versioning for admin endpoints:**
- Issue: Admin endpoints (`/admin/hitl/queue`, `/admin/redteam/jobs`, `/admin/suggest-tuning`) have no versioning scheme.
- Files: `harness/hitl/router.py`, `harness/redteam/router.py`, `harness/proxy/admin.py`
- Impact: Any breaking change to admin endpoints requires coordinated client updates. Low risk for single-workstation use.
- Fix approach: Add `/api/v1/` prefix to admin routes if multi-user adoption grows.

## Known Issues

**No TODO/FIXME/HACK comments found in production code.**
Verification scans across all harness Python files and shell scripts found zero TODO/FIXME/HACK comments. Previous planning documents confirm these were cleaned up during implementation phases.

## Test Coverage Gaps

**No integration tests for the full proxy pipeline:**
- What's not tested: A request through the complete pipeline (auth -> rate limit -> guardrails -> proxy -> critique -> PII redact -> trace write).
- Files: `harness/tests/test_proxy.py` (unit tests mock individual components)
- Risk: Pipeline interaction bugs (e.g., guardrail decision format mismatch between engine and proxy) can go undetected.
- Priority: Medium

**No load/stress tests:**
- What's not tested: Performance under concurrent load, SQLite contention behavior, rate limiter accuracy under burst traffic.
- Files: None exist
- Risk: Latency regressions and contention issues not detected before deployment.
- Priority: Low (single-workstation tool)

**No container launcher integration tests in CI:**
- What's not tested: Verify that `start-vllm.sh`, `start-litellm.sh`, etc. successfully start services and serve requests.
- Files: All scripts in `inference/`, `eval/`, `data/`
- Risk: Silent failures in launcher scripts not caught until production use.
- Priority: Medium

**No Dockerfile build reproducibility tests:**
- What's not tested: Build reproducibility, layer caching, and size verification for the three Dockerfiles.
- Files: `base-toolbox/Dockerfile`, `eval-toolbox/Dockerfile`, `data-toolbox/Dockerfile`
- Risk: Build failures due to upstream package changes not caught until manual build attempt.
- Priority: Medium

## Dependencies at Risk

**NeMo Guardrails version coupling:**
- Risk: `nemoguardrails>=0.21` is a fast-moving NVIDIA library with frequent breaking API changes.
- Files: `harness/pyproject.toml:25`
- Impact: NeMo API changes break guardrail initialization silently (fail-open means broken NeMo = no safety).
- Migration plan: Pin to a specific NeMo version and test upgrades explicitly.

**Gradio major version constraint:**
- Risk: `gradio>=6.0,<7.0` — the HITL dashboard uses Gradio 6 APIs with a workaround for PEP 563 annotation conflicts with `gr.SelectData`.
- Files: `harness/pyproject.toml:27`, `harness/hitl/ui.py:156-163,231-236`
- Impact: Gradio 7 migration will require reworking the SelectData annotation workaround and possibly the Dataframe API.
- Migration plan: Test with Gradio 7 pre-releases when available; the workaround is well-documented in comments.

**LiteLLM rolling tag (`main-latest`):**
- Risk: `inference/start-litellm.sh` and `docker-compose.inference.yml` use `ghcr.io/berriai/litellm:main-latest`, which is an unstable rolling tag.
- Files: `inference/start-litellm.sh:4`, `docker-compose.inference.yml:36`
- Impact: New versions may introduce breaking API changes or configuration format changes without warning.
- Migration plan: Pin to a stable release tag.

## Scaling Limits

**SQLite as primary data store:**
- Current capacity: Adequate for single-workstation use (thousands of traces per day).
- Limit: SQLite write throughput is ~50-100 writes/sec with WAL mode. Connection-per-operation pattern amplifies contention under high concurrency (>50 concurrent requests).
- Scaling path: For multi-node deployment, migrate to PostgreSQL. For single-node high-throughput, maintain a persistent connection and batch writes.

**Single GPU shared across all containers:**
- Current capacity: All inference servers (vLLM, Triton, Ollama) and tools (Unsloth, eval-toolbox) share `--gpus all`.
- Limit: GPU memory is not partitioned. If vLLM loads a large model, other containers may OOM.
- Scaling path: Implement GPU memory limits per container. Use `CUDA_VISIBLE_DEVICES` or MIG partitioning on supported hardware.

---

*Concerns audit: 2026-04-01*
