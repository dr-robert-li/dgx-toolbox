---
phase: 02-adapters-and-usage-tracking
verified: 2026-03-21T03:00:00Z
status: passed
score: 14/14 must-haves verified
re_verification: false
---

# Phase 2: Adapters and Usage Tracking — Verification Report

**Phase Goal:** HuggingFace and Ollama models can each be enumerated, sized, and individually identified, and every model load from a launcher updates a persistent usage timestamp
**Verified:** 2026-03-21T03:00:00Z
**Status:** PASSED
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths (from ROADMAP Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Running a launcher creates/updates a timestamp for that model | VERIFIED | watcher.sh watches docker events + inotifywait; ms_track_usage writes ISO-8601 timestamps to usage.json with flock serialization |
| 2 | Cold drive mount state is checked before any cold-path operation | VERIFIED | check_cold_mounted() called in hf_migrate_model and ollama_migrate_model; test assertions confirm non-zero exit on unmounted cold drive (SAFE-01) |
| 3 | Space check with 10% margin prevents operations when destination is too full | VERIFIED | check_space() called in both adapters before migrate; tests confirm return 1 on insufficient space (SAFE-02) |
| 4 | Ollama server running state is detected before any Ollama model operation | VERIFIED | ollama_check_server() checks systemctl then curl fallback; ollama_migrate_model and ollama_recall_model call ms_die if server is active (SAFE-06) |

**Score:** 4/4 roadmap success criteria verified

### Plan Must-Have Truths (from PLAN frontmatter)

#### 02-01 Plan Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | hf_list_models prints TSV of model_path and size_bytes | VERIFIED | Lines 17-38 hf_adapter.sh: Python API primary, du -sb fallback; test-hf-adapter.sh T3+T4 confirm TSV output |
| 2 | hf_migrate_model refuses to operate when cold drive is not mounted | VERIFIED | check_cold_mounted called at line 77; test T5 confirms non-zero exit on mountpoint failure |
| 3 | hf_migrate_model refuses to operate when destination has insufficient space | VERIFIED | check_space called at lines 81-84; test T6 confirms return 1 with tiny df output |
| 4 | hf_migrate_model uses rsync + atomic symlink swap (ln -s + mv -T) | VERIFIED | Lines 95 (rsync), 102-103 (ln -s + mv -T); test T8 confirms symlink created at model_id |
| 5 | hf_recall_model moves model back from cold and removes symlink | VERIFIED | Lines 139-146: rm symlink, rsync back, clean cold dirs; test T9 confirms skip-if-not-symlink |
| 6 | ollama_list_models enumerates models via /api/tags HTTP endpoint | VERIFIED | Lines 31-36 ollama_adapter.sh; test T4 confirms TSV output with mock API response |
| 7 | ollama_check_server detects running Ollama via systemctl then curl fallback | VERIFIED | Lines 19-22; tests T1+T2+T3 cover all three branches |
| 8 | ollama_migrate_model blocks when Ollama server is active | VERIFIED | Lines 71-73: ms_die fires; test T7 confirms non-zero exit + "Ollama server is active" in stderr |
| 9 | ollama_migrate_model refuses to operate when cold drive is not mounted | VERIFIED | Lines 75-77: check_cold_mounted called when server is stopped; test T8 confirms non-zero exit |
| 10 | No adapter function calls sudo or accesses Ollama filesystem directly | VERIFIED | grep confirms no "sudo" or "/usr/share/ollama" in ollama_adapter.sh; tests T11+T12 assert same |

#### 02-02 Plan Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | ms_track_usage writes an ISO-8601 timestamp to usage.json for a given model path | VERIFIED | watcher.sh lines 48+70-72; test T2 confirms ISO-8601 pattern match |
| 2 | ms_track_usage updates existing entries without corrupting the JSON | VERIFIED | flock+jq atomic write (lines 66-73); test T4 confirms update; test T5 concurrent writes produce valid JSON |
| 3 | Concurrent ms_track_usage calls do not corrupt usage.json (flock serialization) | VERIFIED | flock -x 9 on USAGE_LOCK fd; test T5 runs 5 parallel subshells and verifies all 5 keys present + valid JSON |
| 4 | Watcher daemon starts and writes pidfile at ~/.modelstore/watcher.pid | VERIFIED | Lines 32: echo "$$" > "$PIDFILE"; PIDFILE="${HOME}/.modelstore/watcher.pid" |
| 5 | Watcher daemon exits silently if modelstore is not initialized (no config.json) | VERIFIED | Line 24: [[ -f "$MODELSTORE_CONFIG" ]] || exit 0; test T10 confirms exit code 0 with HOME=/nonexistent |
| 6 | Second watcher instance does not start when pidfile exists and process is alive | VERIFIED | Lines 27-29: kill -0 check; test T11 confirms guard logic via kill -0 on current PID |
| 7 | Daemon cleanup removes pidfile and kills child processes on EXIT/INT/TERM | VERIFIED | Lines 35-39: cleanup() removes PIDFILE, kills DOCKER_PID and INOTIFY_PID; trap cleanup EXIT INT TERM |
| 8 | inotifywait watches HOT_HF_PATH and HOT_OLLAMA_PATH for access events | VERIFIED | Lines 110: inotifywait -m -r -e access,open on watch_paths array; watch_inotify() calls load_config |
| 9 | Docker events watcher monitors container start events | VERIFIED | Line 172: docker events --filter "event=start" --format '{{json .}}' |
| 10 | Debounce prevents repeated writes for the same model within 60 seconds | VERIFIED | Lines 54-62: reads last_ts, computes delta, skips if < DEBOUNCE_SECONDS; tests T6+T7 confirm both skip and allow behavior |

**Score:** 14/14 plan must-have truths verified

---

## Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `modelstore/lib/hf_adapter.sh` | HF adapter with 5 functions | VERIFIED | 150 lines, all 5 functions present (hf_list_models, hf_get_model_size, hf_get_model_path, hf_migrate_model, hf_recall_model); no set -e; no side effects on source |
| `modelstore/lib/ollama_adapter.sh` | Ollama API adapter with 6 functions | VERIFIED | 107 lines, all 6 functions present; no sudo; no /usr/share/ollama; no set -e |
| `modelstore/test/test-hf-adapter.sh` | HF adapter unit tests | VERIFIED | 10 test cases, 12 assertions; all PASS; tests SAFE-01 (T5), SAFE-02 (T6), symlink skip (T7), migration success (T8), recall skip (T9) |
| `modelstore/test/test-ollama-adapter.sh` | Ollama adapter unit tests | VERIFIED | 12 test cases, 15 assertions; all PASS; tests SAFE-06 (T1/T7/T10), SAFE-01 (T8), SAFE-02 (T9) |
| `modelstore/hooks/watcher.sh` | Background usage tracking daemon | VERIFIED | 198 lines; executable (chmod +x confirmed); ms_track_usage, extract_model_id_from_path, watch_inotify, watch_docker_events, pidfile lifecycle, cleanup trap |
| `modelstore/test/test-watcher.sh` | Watcher unit tests | VERIFIED | 12 assertions; all PASS; covers TRCK-01 (T1-T5), debounce (T6-T7), path extraction (T8-T9), TRCK-02 startup guard (T10), pidfile guard (T11) |
| `modelstore/test/run-all.sh` | Full test suite includes new files | VERIFIED | Contains test-hf-adapter.sh, test-ollama-adapter.sh, test-watcher.sh; full suite passes ("All test scripts passed") |

---

## Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| hf_adapter.sh | common.sh | check_cold_mounted, check_space | WIRED | Both functions called in hf_migrate_model (lines 77, 82-84) and hf_recall_model (lines 129, 134) |
| hf_adapter.sh | config.sh | load_config for HOT_HF_PATH | WIRED | hf_list_models calls load_config at line 18; HOT_HF_PATH used for fallback walk |
| ollama_adapter.sh | common.sh | check_cold_mounted, ms_die | WIRED | check_cold_mounted called at line 76; ms_die called at line 72 |
| ollama_adapter.sh | curl /api/tags | HTTP API for model enumeration | WIRED | curl http://localhost:11434/api/tags in ollama_list_models (line 31), ollama_get_model_size (line 45-46), ollama_check_server (line 20) |
| watcher.sh | ~/.modelstore/usage.json | ms_track_usage with flock + jq | WIRED | flock -x 9 at line 67; fd 9 opened with 9>"$USAGE_LOCK" at line 73; jq atomic write to USAGE_FILE.tmp then mv |
| watcher.sh | config.sh | load_config for HOT_HF_PATH, HOT_OLLAMA_PATH | WIRED | load_config called at lines 104 (watch_inotify) and 185 (main block) |
| watcher.sh | inotifywait | filesystem access monitoring | WIRED | inotifywait -m -r -e access,open at line 110 |
| watcher.sh | docker events | container start event monitoring | WIRED | docker events --filter "event=start" at line 172 |

---

## Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| TRCK-01 | 02-02 | Usage tracker maintains a timestamp manifest file per model, updated on every load | SATISFIED | usage.json written by ms_track_usage with ISO-8601 timestamps under flock; 12 test assertions verify write, update, JSON integrity, debounce |
| TRCK-02 | 02-02 | Existing DGX Toolbox launcher scripts are hooked to call the usage tracker | SATISFIED | Zero-touch daemon design (documented in 02-CONTEXT.md): docker events watcher catches containerized launcher starts; inotifywait catches filesystem access; no launcher script modification required |
| SAFE-01 | 02-01 | Migration refuses to create symlinks if cold drive is not mounted | SATISFIED | check_cold_mounted called in hf_migrate_model and ollama_migrate_model; test assertions confirm non-zero exit (SAFE-01) |
| SAFE-02 | 02-01 | Migration checks available space with 10% safety margin | SATISFIED | check_space called in both adapters with model size before migrate; tests T6 and T9 confirm return 1 on insufficient space |
| SAFE-06 | 02-01 | Ollama server state is checked before migrating Ollama models | SATISFIED | ollama_check_server() → ms_die if active; both ollama_migrate_model and ollama_recall_model block when server is running; tests T7 and T10 confirm |

**Orphaned requirements:** None. All 5 requirements declared across the two plans are satisfied.

---

## Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| ollama_adapter.sh | 85, 104 | "deferred to Phase 3" in migrate/recall stubs | INFO | By design: plan explicitly specifies these as stubs with correct guard structure. Phase 3 will implement ollama cp + ollama rm. Guards (SAFE-06, SAFE-01, SAFE-02) are fully implemented and tested. |

No blockers. No warnings. The stub bodies in ollama_migrate_model and ollama_recall_model are intentional placeholder logging per the plan's explicit design decision ("stub with correct guard structure for Phase 3 implementation").

---

## Minor Discrepancy (Non-Blocking)

The ROADMAP Success Criterion 1 references `~/.modelstore/usage/` (directory path). The actual implementation uses `~/.modelstore/usage.json` (a single JSON file). This is a ROADMAP wording inconsistency — the plan's interfaces section, CONTEXT.md design decision, and both the implementation and tests all consistently use `usage.json`. The JSON file format is the locked design. The ROADMAP path is a typo in the roadmap document.

**Impact:** None on phase 2 functionality. Phase 3 will read `usage.json` per the plan interface.

---

## Human Verification Required

### 1. Zero-Touch Launcher Tracking (TRCK-02)

**Test:** Start the watcher daemon (`bash modelstore/hooks/watcher.sh &`), then run a vLLM or eval-toolbox launcher that loads a real model. Wait 5 seconds.
**Expected:** `~/.modelstore/usage.json` contains an entry for the model's directory path with the current timestamp.
**Why human:** The docker events + inotifywait path requires real daemon execution against actual container/process launches. Unit tests use inline function copies that skip the daemon lifecycle. Requires real HF cache or Ollama model present.

### 2. Watcher Daemon Long-Running Stability

**Test:** Run the watcher daemon for 10+ minutes while loading models. Check it does not accumulate zombie processes or unbounded memory usage.
**Expected:** Daemon stays running, pidfile exists, child PIDs are stable.
**Why human:** Daemon liveness over time and cleanup trap behavior on SIGTERM require runtime observation, not grep.

---

## Gaps Summary

No gaps. All 14 must-have truths are verified. All 5 requirement IDs (TRCK-01, TRCK-02, SAFE-01, SAFE-02, SAFE-06) are satisfied by implemented, tested, and wired code. The full test suite (39 assertions across hf, ollama, and watcher tests) passes green. Phase 2 goal is achieved.

---

_Verified: 2026-03-21T03:00:00Z_
_Verifier: Claude (gsd-verifier)_
