---
phase: 09-red-teaming
verified: 2026-03-23T00:00:00Z
status: passed
score: 17/17 must-haves verified
re_verification: false
---

# Phase 9: Red Teaming Verification Report

**Phase Goal:** The harness mines its own failure history to generate adversarial prompts, runs garak one-shot vulnerability scans, executes deepteam feedback-loop generation, and dispatches all long-running jobs asynchronously — with dataset balance enforced in code
**Verified:** 2026-03-23
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| #  | Truth | Status | Evidence |
|----|-------|--------|---------|
| 1  | redteam_jobs table exists in traces.db with correct CHECK constraints | VERIFIED | schema.sql lines 35-45: `CHECK(type IN ('garak', 'deepteam'))` and `CHECK(status IN ('pending', 'running', 'complete', 'failed'))` present |
| 2  | TraceStore can create, update, query, and list red team jobs | VERIFIED | store.py: `create_job` (L153), `update_job_status` (L170), `get_job` (L199), `list_jobs` (L218) all implemented with aiosqlite |
| 3  | TraceStore can query near-miss traces (scored above threshold, not blocked) | VERIFIED | store.py L242: `query_near_misses` — SQL filters `refusal_event = 0` + Python filter `any(r.get("score",0) > 0 ...)` |
| 4  | Balance check rejects datasets where any category exceeds max_category_ratio | VERIFIED | balance.py L44-49: computes per-category ratios and returns violations dict when ratio > max_category_ratio |
| 5  | Balance check passes datasets within ratio limits | VERIFIED | balance.py returns `(True, {})` when all categories within limit |
| 6  | garak profile YAML files exist with correct plugins.generators.openai.OpenAICompatible.uri nesting | VERIFIED | All three profiles (quick, standard, thorough) contain correct nesting; verified by reading files |
| 7  | POST /admin/redteam/jobs with type=garak returns 202 with job_id | VERIFIED | router.py L33-61: submit_job returns `JSONResponse(status_code=202, content={"job_id": ..., "status": "pending"})` |
| 8  | POST /admin/redteam/jobs with type=deepteam returns 202 with job_id | VERIFIED | Same submit_job handler handles both type="garak" and type="deepteam" |
| 9  | GET /admin/redteam/jobs/{job_id} returns job status and result | VERIFIED | router.py L162-172: `get_job_status` endpoint fetches from trace_store, returns 404 if not found |
| 10 | GET /admin/redteam/jobs returns list of jobs | VERIFIED | router.py L175-183: `list_jobs` endpoint calls trace_store.list_jobs |
| 11 | Second job submission while one running returns 409 Conflict | VERIFIED | router.py L40-46: `lock.locked()` check returns 409 with running job_id |
| 12 | garak runner invokes asyncio.create_subprocess_exec with correct flags | VERIFIED | garak_runner.py L48-52: uses `asyncio.create_subprocess_exec` with `--config` and `--report_prefix` flags, sets OPENAICOMPATIBLE_API_KEY in env |
| 13 | garak runner parses JSONL report and returns scores dict | VERIFIED | garak_runner.py L68-96: `parse_garak_report` reads JSONL, filters `entry_type=="eval"`, returns probe->scores dict |
| 14 | deepteam engine queries near-miss traces and sends to judge model | VERIFIED | engine.py L89-90: calls `trace_store.query_near_misses`, then loops over results calling `generate_adversarial_variants` with http_client |
| 15 | deepteam engine writes adversarial variants to pending JSONL with prompt/category/technique | VERIFIED | engine.py L119-125: writes to `PENDING_DIR / f"deepteam-{ts}.jsonl"` with one JSON object per line |
| 16 | python -m harness.redteam promote runs balance check before copying | VERIFIED | __main__.py L25: `check_balance(pending_file, ACTIVE_DIR, max_ratio)` called before `shutil.move` |
| 17 | promote rejects file when balance check fails | VERIFIED | __main__.py L26-31: on `not ok`, prints violations and calls `sys.exit(1)` before any file move |

**Score:** 17/17 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `harness/traces/schema.sql` | redteam_jobs DDL | VERIFIED | Contains `CREATE TABLE IF NOT EXISTS redteam_jobs` with CHECK constraints; appended after existing DDL |
| `harness/traces/store.py` | Job CRUD + near-miss query methods | VERIFIED | 5 new methods: create_job, update_job_status, get_job, list_jobs, query_near_misses |
| `harness/redteam/balance.py` | Dataset balance enforcement | VERIFIED | `check_balance` function with max_category_ratio parameter, Counter-based category ratio logic |
| `harness/config/redteam.yaml` | Red team config with max_category_ratio and near_miss_window_days | VERIFIED | Contains max_category_ratio: 0.40, near_miss_window_days: 7, plus 4 other settings |
| `harness/config/redteam_quick.yaml` | Quick garak scan profile | VERIFIED | Contains `OpenAICompatible` with correct `plugins.generators.openai.OpenAICompatible.uri` nesting |
| `harness/config/redteam_standard.yaml` | Standard garak scan profile | VERIFIED | Correct nesting, 10-20 min scan |
| `harness/config/redteam_thorough.yaml` | Thorough garak scan profile | VERIFIED | Correct nesting, 30-60 min scan |
| `harness/redteam/garak_runner.py` | garak subprocess wrapper | VERIFIED | `run_garak_scan` + `parse_garak_report` both implemented, non-stub |
| `harness/redteam/engine.py` | Adversarial generation from near-miss traces | VERIFIED | `generate_adversarial_variants` + `run_deepteam_job` both implemented |
| `harness/redteam/router.py` | Admin endpoints for job submit/status/list | VERIFIED | `redteam_router` with POST /jobs, GET /jobs/{id}, GET /jobs |
| `harness/redteam/__main__.py` | CLI for promote command | VERIFIED | `cmd_promote` with balance check + `cmd_list`, main() dispatcher |
| `harness/main.py` | Router registration + lock init in lifespan | VERIFIED | `redteam_lock`, `redteam_current_job_id`, `redteam_active_task` initialized; `redteam_router` included |
| `harness/eval/datasets/pending/.gitkeep` | Staging directory | VERIFIED | Directory and .gitkeep file exist |
| `harness/tests/test_redteam_data.py` | Plan 01 test coverage | VERIFIED | 12.7K — covers schema, CRUD, near-miss, and balance tests |
| `harness/tests/test_redteam.py` | Plan 02 test coverage | VERIFIED | 20.1K — covers garak runner, engine, router endpoints, CLI promote |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `harness/traces/store.py` | `harness/traces/schema.sql` | `init_db` reads schema.sql and executes DDL | WIRED | L31-34: `schema_path = Path(__file__).parent / "schema.sql"` + `db.executescript(schema)` — redteam_jobs DDL is in schema.sql so will be created at startup |
| `harness/redteam/balance.py` | `harness/eval/datasets/` | `active_dataset_dir.glob("*.jsonl")` | WIRED | balance.py L27: `active_dataset_dir.glob("*.jsonl")` scans active datasets; __main__.py passes `ACTIVE_DIR` |
| `harness/redteam/router.py` | `harness/traces/store.py` | `request.app.state.trace_store` for job CRUD | WIRED | router.py L54-55, L169, L182: trace_store.create_job, get_job, list_jobs all called via app.state |
| `harness/redteam/router.py` | `harness/redteam/garak_runner.py` | `asyncio.create_task` dispatching run_garak_scan | WIRED | router.py L58: `asyncio.create_task(_run_job(...))`, L85: lazy import + `await run_garak_scan(...)` |
| `harness/redteam/router.py` | `harness/redteam/engine.py` | `asyncio.create_task` dispatching run_deepteam_job | WIRED | router.py L132: lazy import + `await run_deepteam_job(...)` via `_dispatch_deepteam` |
| `harness/redteam/engine.py` | `harness/traces/store.py` | `query_near_misses` for adversarial generation input | WIRED | engine.py L90: `await trace_store.query_near_misses(since=since, limit=near_miss_limit)` |
| `harness/redteam/__main__.py` | `harness/redteam/balance.py` | `check_balance` before promote | WIRED | __main__.py L10: `from harness.redteam.balance import check_balance`; L25: called before shutil.move |
| `harness/main.py` | `harness/redteam/router.py` | `app.include_router(redteam_router)` | WIRED | main.py L96-97: `from harness.redteam.router import redteam_router` + `app.include_router(redteam_router)` |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|---------|
| RDTM-01 | 09-02-PLAN.md | garak runs one-shot vulnerability scans against the gateway endpoint | SATISFIED | garak_runner.py: asyncio.create_subprocess_exec with --config flag targeting gateway; router exposes /admin/redteam/jobs for triggering |
| RDTM-02 | 09-02-PLAN.md | Adversarial prompts generated from past critiques, evals, and trace logs via deepteam | SATISFIED | engine.py: query_near_misses retrieves trace history; generate_adversarial_variants sends to judge model; run_deepteam_job orchestrates the full feedback loop |
| RDTM-03 | 09-01-PLAN.md, 09-02-PLAN.md | Red team jobs run asynchronously | SATISFIED | router.py L58: `asyncio.create_task(_run_job(...))` dispatches without blocking; lock prevents concurrent jobs; 202 returned immediately |
| RDTM-04 | 09-01-PLAN.md, 09-02-PLAN.md | Generated adversarial datasets balanced to prevent category drift | SATISFIED | balance.py: check_balance enforces max_category_ratio=0.40; __main__.py: promote command runs check before copying; 33 tests all pass |

**Note on RDTM-03:** Requirements.md states "via Celery/Redis" but the implementation uses asyncio.Lock + asyncio.create_task within the FastAPI event loop. The PLAN explicitly chose asyncio.Lock over Celery (citing research) and the requirement's intent — async dispatch with concurrency control — is fully achieved. This is a deliberate design decision documented in the plan research.

### Anti-Patterns Found

No anti-patterns detected. Scanned all 5 redteam module files and both test files for:
- TODO/FIXME/HACK/PLACEHOLDER comments
- Empty stub returns (return null, return {}, return [])
- Not-implemented raises

### Human Verification Required

None. All phase behaviors are verifiable through code inspection and automated tests.

### Test Results

All 33 tests in `test_redteam_data.py` (12 schema/CRUD/near-miss tests + 5 balance tests) and `test_redteam.py` (8 garak/engine tests + 8 router/CLI tests) pass with zero failures.

### Gaps Summary

No gaps. All 17 observable truths are verified, all artifacts exist at all three levels (exists, substantive, wired), all key links are confirmed connected, and all 4 requirements are satisfied.

---

_Verified: 2026-03-23_
_Verifier: Claude (gsd-verifier)_
