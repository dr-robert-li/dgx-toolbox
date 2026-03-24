# Phase 12: Demo and Documentation - Context

**Gathered:** 2026-03-24
**Status:** Ready for planning

<domain>
## Phase Boundary

Runnable demo script and README walkthrough proving the full data→training→safety eval→inference pipeline works end-to-end. Final phase of v1.2 Autoresearch Integration.

</domain>

<decisions>
## Implementation Decisions

### Demo script scope
- **Short real training over 3 cycles** (~24 minutes of autoresearch): real training, real checkpoint, real safety eval. Proves the full pipeline actually works, not simulated
- **Data source**: User chooses — built-in autoresearch dataset or their own via any of the existing options (local dir, HuggingFace, GitHub, Kaggle). Demo script presents the same data source menu as the launcher
- **Full summary at end**: Print dataset used, training cycles completed, safety eval result (pass/fail + F1), registered model name, and the curl command to query it through the harness

### README walkthrough
- Claude's discretion on depth and structure — cover each pipeline stage with commands, expected output, and troubleshooting

### Claude's Discretion
- README walkthrough structure, depth, and formatting
- Demo script error handling and cleanup behavior
- Whether to add demo aliases to example.bash_aliases
- How to handle the case where user doesn't have a GPU available for training

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase 11 scripts (what the demo exercises)
- `karpathy-autoresearch/launch-autoresearch.sh` — Interactive launcher with 6-option data source menu + HF model selection
- `scripts/screen-data.sh` — Training data pre-screening through harness guardrails
- `scripts/eval-checkpoint.sh` — Post-training safety eval with temp vLLM + auto-registration
- `scripts/autoresearch-deregister.sh` — Model deregistration from LiteLLM
- `scripts/_litellm_register.py` — LiteLLM config YAML manipulation

### Existing docs
- `README.md` — Current README with Safety Harness section; add autoresearch pipeline walkthrough
- `CHANGELOG.md` — Update with v1.2 entry
- `example.bash_aliases` — May need demo alias

### Project context
- `.planning/PROJECT.md` — v1.2 milestone goals
- `.planning/REQUIREMENTS.md` — DEMO-01, DEMO-02

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `launch-autoresearch.sh`: Full data source menu — demo script can source or call this
- `scripts/eval-checkpoint.sh`: Full eval + register pipeline — demo calls this after training
- `scripts/screen-data.sh`: Optional pre-screening step

### Integration Points
- `scripts/demo-autoresearch.sh` — New demo script
- `README.md` — Add "Autoresearch Pipeline" section with walkthrough

</code_context>

<specifics>
## Specific Ideas

- The demo script should orchestrate: clone/pull autoresearch → present data source menu → optional screen-data → run 3 training cycles → eval-checkpoint → print summary with curl command
- The 3-cycle training limit can be achieved by modifying autoresearch's config or by sending SIGINT after 3 cycles complete
- The final curl command should be copy-pasteable: `curl -s -X POST http://localhost:5000/v1/chat/completions -H "Authorization: Bearer sk-devteam-test" -H "Content-Type: application/json" -d '{"model": "autoresearch/exp-xxx", "messages": [{"role": "user", "content": "Hello"}]}'`

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 12-demo-and-documentation*
*Context gathered: 2026-03-24*
