---
phase: 04-cli-status-revert-and-docs
plan: 02
subsystem: infra
tags: [bash, reorganization, documentation, rsync, modelstore, ttyd]

# Dependency graph
requires:
  - phase: 04-cli-status-revert-and-docs
    provides: status.sh and revert.sh CLI commands from 04-01

provides:
  - 25 launcher scripts organized into inference/, data/, eval/, containers/, setup/ subdirectories
  - TTY-guarded rsync progress bars in hf_adapter.sh and ollama_adapter.sh
  - Updated example.bash_aliases with subdirectory paths and modelstore alias
  - Updated README.md with Model Store section, corrected Sync app table, updated script paths
  - Updated CHANGELOG.md with 2026-03-22 Model Store release entry
  - Updated .gitignore with modelstore test artifact exclusions

affects: [any future documentation updates, cron headless execution, modelstore adapters]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "TTY guard: [[ -t 1 ]] && rsync_flags+=\" --info=progress2\" — conditional progress bars for terminal vs headless"
    - "Category subdirectory layout: inference/, data/, eval/, containers/, setup/ for 25 root scripts"
    - "lib.sh relative source: source \"$(dirname \"$0\")/../lib.sh\" for scripts in subdirectories"

key-files:
  created:
    - inference/ (8 scripts moved here)
    - data/ (5 scripts moved here)
    - eval/ (5 scripts moved here)
    - containers/ (6 scripts moved here)
    - setup/ (1 script moved here)
  modified:
    - inference/start-open-webui.sh — lib.sh source path updated
    - inference/start-open-webui-sync.sh — lib.sh source path updated
    - containers/start-n8n.sh — lib.sh source path updated
    - data/start-label-studio.sh — lib.sh source path updated
    - data/start-argilla.sh — lib.sh source path updated
    - modelstore/lib/hf_adapter.sh — TTY guard on rsync in migrate and recall
    - modelstore/lib/ollama_adapter.sh — TTY guard on rsync in migrate and recall
    - example.bash_aliases — all paths updated, modelstore alias added
    - README.md — Model Store section, updated all script paths, Sync app table
    - CHANGELOG.md — 2026-03-22 Model Store release entry
    - .gitignore — modelstore test artifact exclusions

key-decisions:
  - "rsync_flags variable approach (not inline flag substitution) for TTY guard — readable and handles multiple flags cleanly"
  - "modelstore.sh stays in root alongside status.sh and lib.sh (not moved to setup/)"
  - "Model Store README section placed before Port Reference for discovery flow"

patterns-established:
  - "TTY guard pattern: local rsync_flags=\"-a\"; [[ -t 1 ]] && rsync_flags+=\" --info=progress2\"; rsync $rsync_flags"
  - "Subdirectory lib.sh sourcing: source \"$(dirname \"$0\")/../lib.sh\""

requirements-completed: [CLI-02, CLI-06, DOCS-01, DOCS-02, DOCS-03, DOCS-04]

# Metrics
duration: 15min
completed: 2026-03-22
---

# Phase 4 Plan 2: CLI Status Revert and Docs Summary

**Root reorganized into 5 category subdirectories (25 scripts), rsync progress bars TTY-guarded for headless cron, and all docs updated with Model Store section and corrected paths**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-03-22T00:00:00Z
- **Completed:** 2026-03-22T00:15:00Z
- **Tasks:** 3 (2 auto + 1 checkpoint)
- **Files modified:** 34

## Accomplishments

- Moved 25 launcher scripts from root into inference/, data/, eval/, containers/, setup/ subdirectories; updated lib.sh source paths in 5 scripts; all pass bash -n
- Added TTY-guarded rsync progress bars in hf_adapter.sh and ollama_adapter.sh so cron/headless runs get clean output without noise
- Updated example.bash_aliases (18 path updates + modelstore alias), README.md (Model Store section + Sync app table + all script path references), CHANGELOG.md, .gitignore

## Task Commits

Each task was committed atomically:

1. **Task 1a: Reorganize root into subdirectories** - `a20086f` (feat)
2. **Task 1b: Add progress bar TTY guards to adapter rsync calls** - `42a64bc` (feat)
3. **Task 2: Update documentation** - `8028982` (docs)
4. **Deviation fix: mock rsync directory structure in test-hf-adapter.sh** - `4ffd502` (fix)

## Files Created/Modified

- `inference/` (8 scripts) - vLLM, LiteLLM, Open-WebUI launchers and sync variants, setup-litellm-config, setup-ollama-remote
- `data/` (5 scripts) - data-toolbox, data-toolbox-build, data-toolbox-jupyter, start-label-studio, start-argilla
- `eval/` (5 scripts) - eval-toolbox, eval-toolbox-build, eval-toolbox-jupyter, triton-trtllm, triton-trtllm-sync
- `containers/` (6 scripts) - ngc-pytorch, ngc-jupyter, ngc-quickstart, unsloth-studio, unsloth-studio-sync, start-n8n
- `setup/` (1 script) - dgx-global-base-setup
- `inference/start-open-webui.sh` and `start-open-webui-sync.sh` - lib.sh path updated to ../lib.sh
- `containers/start-n8n.sh` - lib.sh path updated to ../lib.sh
- `data/start-label-studio.sh` and `start-argilla.sh` - lib.sh path updated to ../lib.sh
- `modelstore/lib/hf_adapter.sh` - TTY guard on rsync in hf_migrate_model and hf_recall_model
- `modelstore/lib/ollama_adapter.sh` - TTY guard on rsync in ollama_migrate_model blob loop and ollama_recall_model
- `example.bash_aliases` - all 18 script paths updated to subdirectory locations, modelstore alias added
- `README.md` - Model Store section with subcommands table, all script path references updated, Sync app table updated with new paths and modelstore entry
- `CHANGELOG.md` - 2026-03-22 Model Store release entry
- `.gitignore` - modelstore/test/tmp* exclusions

## Decisions Made

- rsync_flags variable approach used for TTY guard (not inline flag substitution) — cleaner, allows future flag additions
- modelstore.sh kept in root alongside status.sh and lib.sh (not moved to any subdirectory)
- Model Store README section placed before Port Reference section for natural discovery flow

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed mock rsync in test-hf-adapter.sh to preserve directory structure**
- **Found during:** Task 1b (TTY guard implementation — full test suite run revealed failures)
- **Issue:** Mock rsync function in test-hf-adapter.sh only created the destination directory but did not copy source contents, causing hf_migrate_model post-condition checks to fail (model files absent in cold destination)
- **Fix:** Changed mock rsync to use `cp -r "$src/" "$dst/"` so directory contents are preserved, matching real rsync behavior
- **Files modified:** modelstore/test/test-hf-adapter.sh
- **Verification:** bash modelstore/test/run-all.sh passed (all tests green)
- **Committed in:** 4ffd502 (separate fix commit after task 1b)

---

**Total deviations:** 1 auto-fixed (Rule 1 - bug)
**Impact on plan:** Fix necessary for test correctness; no scope creep.

## Issues Encountered

None beyond the auto-fixed test mock issue above.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- All 4 phases complete — project at 100%
- Users should re-copy example.bash_aliases: `cp ~/dgx-toolbox/example.bash_aliases ~/.bash_aliases && source ~/.bash_aliases`
- Cron scripts in modelstore/cron/ already headless-compatible (no TTY assumption); TTY guards now ensure adapters are also clean

## Self-Check: PASSED

All key files verified present. All task commits verified in git log (a20086f, 42a64bc, 8028982, 4ffd502). Task 3 human-verify checkpoint approved by user.

---
*Phase: 04-cli-status-revert-and-docs*
*Completed: 2026-03-22*
