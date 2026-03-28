---
phase: quick
plan: 260328-fkw
type: execute
wave: 1
depends_on: []
files_modified:
  - lib.sh
  - containers/unsloth-studio.sh
  - containers/unsloth-studio-sync.sh
  - containers/ngc-pytorch.sh
  - containers/ngc-jupyter.sh
  - containers/start-n8n.sh
autonomous: true
requirements: []

must_haves:
  truths:
    - "EXTRA_MOUNTS env var with comma-separated host:container pairs adds -v flags to all container scripts"
    - "Empty or unset EXTRA_MOUNTS produces no extra flags (no breakage)"
    - "Invalid mount specs (missing colon, empty segments) are skipped with a warning"
  artifacts:
    - path: "lib.sh"
      provides: "build_extra_mounts() function"
      contains: "build_extra_mounts"
    - path: "containers/unsloth-studio.sh"
      contains: "build_extra_mounts"
    - path: "containers/unsloth-studio-sync.sh"
      contains: "build_extra_mounts"
    - path: "containers/ngc-pytorch.sh"
      contains: "build_extra_mounts"
    - path: "containers/ngc-jupyter.sh"
      contains: "build_extra_mounts"
    - path: "containers/start-n8n.sh"
      contains: "build_extra_mounts"
  key_links:
    - from: "containers/*.sh"
      to: "lib.sh"
      via: "source lib.sh and call build_extra_mounts"
      pattern: "build_extra_mounts"
---

<objective>
Add flexible extra bind mount support to all container scripts via a shared `build_extra_mounts()` function in lib.sh.

Purpose: Allow users to mount additional host directories into any container without modifying scripts, using the `EXTRA_MOUNTS` environment variable.
Output: Updated lib.sh with shared function, all 5 container scripts wired to use it.
</objective>

<execution_context>
@/home/robert_li/.claude/get-shit-done/workflows/execute-plan.md
@/home/robert_li/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@lib.sh
@containers/unsloth-studio.sh
@containers/unsloth-studio-sync.sh
@containers/ngc-pytorch.sh
@containers/ngc-jupyter.sh
@containers/start-n8n.sh

<interfaces>
From lib.sh — existing functions used by container scripts:
```bash
get_ip()            # Returns LAN IP
is_running()        # Check if container running
container_exists()  # Check if container exists (running or stopped)
ensure_container()  # Start/create persistent container
print_banner()      # Print service URLs
stream_logs()       # Stream container logs
sync_exit()         # Sync-mode exit
ensure_dirs()       # Create directories
```

Container script patterns:
- unsloth-studio.sh, unsloth-studio-sync.sh: Do NOT source lib.sh (inline docker logic)
- ngc-pytorch.sh, ngc-jupyter.sh: Do NOT source lib.sh (standalone docker run)
- start-n8n.sh: Sources lib.sh via `source "$(dirname "$0")/../lib.sh"`
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Add build_extra_mounts() to lib.sh and wire all container scripts</name>
  <files>lib.sh, containers/unsloth-studio.sh, containers/unsloth-studio-sync.sh, containers/ngc-pytorch.sh, containers/ngc-jupyter.sh, containers/start-n8n.sh</files>
  <action>
1. Add `build_extra_mounts()` function to lib.sh (append after `ensure_dirs`):

```bash
# Build extra -v flags from EXTRA_MOUNTS env var
# Format: EXTRA_MOUNTS="/host/a:/container/a,/host/b:/container/b"
# Comma-separated mount specs, each spec is host_path:container_path
# Invalid specs (no colon, empty segments) are skipped with warning to stderr
# Returns: string of "-v /host/a:/container/a -v /host/b:/container/b" or empty
build_extra_mounts() {
  [ -z "${EXTRA_MOUNTS:-}" ] && return 0
  local IFS=','
  local mounts=()
  for spec in $EXTRA_MOUNTS; do
    spec=$(echo "$spec" | xargs)  # trim whitespace
    if [[ "$spec" != *:* ]] || [[ -z "${spec%%:*}" ]] || [[ -z "${spec#*:}" ]]; then
      echo "Warning: skipping invalid mount spec: '$spec'" >&2
      continue
    fi
    mounts+=("-v" "$spec")
  done
  echo "${mounts[*]}"
}
```

2. Wire each container script. The approach differs by script pattern:

**containers/unsloth-studio.sh** — does not source lib.sh. Add source line near top (after `#!/usr/bin/env bash`):
```bash
source "$(dirname "$0")/../lib.sh"
```
Then in the `docker run -d \` block (line 32), add `$(build_extra_mounts) \` as a new line after the existing `-v` lines (before `--restart`).

**containers/unsloth-studio-sync.sh** — same approach. Add source line near top, then add `$(build_extra_mounts) \` in the `docker run -d \` block (line 15) after the existing `-v` lines.

**containers/ngc-pytorch.sh** — does not source lib.sh. Add source line after shebang, then add `$(build_extra_mounts) \` after the existing `-v` lines in the docker run command.

**containers/ngc-jupyter.sh** — same approach. Add source line, add `$(build_extra_mounts) \` after existing `-v` lines.

**containers/start-n8n.sh** — already sources lib.sh. Just add `$(build_extra_mounts) \` in the `create_n8n()` function's docker run, after the `-v ~/.n8n:/home/node/.n8n \` line.

IMPORTANT: The `$(build_extra_mounts)` expansion must NOT be quoted (no double quotes around it) so that bash word-splits the output into separate arguments. If EXTRA_MOUNTS is empty, the expansion produces nothing and docker run proceeds normally.

IMPORTANT: unsloth-studio.sh has inline `is_running`-style checks (docker ps | grep). After sourcing lib.sh those functions become available but the inline checks still work fine — no conflict. Do NOT refactor the inline checks; only add the source line and the extra mounts expansion.
  </action>
  <verify>
    <automated>cd /home/robert_li/dgx-toolbox && bash -c 'source lib.sh && EXTRA_MOUNTS="/tmp/a:/mnt/a,/tmp/b:/mnt/b" && result=$(build_extra_mounts) && echo "$result" && [[ "$result" == "-v /tmp/a:/mnt/a -v /tmp/b:/mnt/b" ]]' && bash -c 'source lib.sh && unset EXTRA_MOUNTS && result=$(build_extra_mounts) && [[ -z "$result" ]]' && bash -c 'source lib.sh && EXTRA_MOUNTS="badspec,/ok:/path" && result=$(build_extra_mounts 2>/dev/null) && [[ "$result" == "-v /ok:/path" ]]' && echo "ALL TESTS PASSED"</automated>
  </verify>
  <done>
    - build_extra_mounts() exists in lib.sh and correctly parses EXTRA_MOUNTS
    - Empty/unset EXTRA_MOUNTS returns empty string
    - Invalid specs produce warning to stderr and are skipped
    - All 5 container scripts source lib.sh and include $(build_extra_mounts) in their docker run commands
  </done>
</task>

</tasks>

<verification>
- `grep -l build_extra_mounts containers/*.sh` returns all 5 container scripts
- `grep build_extra_mounts lib.sh` confirms function definition
- `bash -n containers/*.sh` confirms no syntax errors in any script
- Manual test: `EXTRA_MOUNTS="/tmp/test:/mnt/test" containers/ngc-pytorch.sh` would include `-v /tmp/test:/mnt/test` in docker run (verify via dry-run or inspection)
</verification>

<success_criteria>
- All 5 container scripts support EXTRA_MOUNTS env var for additional bind mounts
- Zero behavior change when EXTRA_MOUNTS is unset (backward compatible)
- Invalid mount specs warn but do not break container launch
- Single shared implementation in lib.sh (DRY)
</success_criteria>

<output>
After completion, create `.planning/quick/260328-fkw-add-flexible-extra-bind-mount-support-to/260328-fkw-SUMMARY.md`
</output>
