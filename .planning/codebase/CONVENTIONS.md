# Coding Conventions

**Analysis Date:** 2026-03-19

## Naming Patterns

**Files:**
- Kebab-case for all shell scripts: `start-vllm.sh`, `setup-litellm-config.sh`, `dgx-global-base-setup.sh`
- Descriptive action prefixes: `start-*` for services, `setup-*` for configuration, `eval-toolbox*` and `data-toolbox*` for toolbox variants
- Build scripts suffixed with `-build.sh`: `eval-toolbox-build.sh`, `data-toolbox-build.sh`
- Sync variants suffixed with `-sync.sh`: `start-vllm-sync.sh`, `start-open-webui-sync.sh`

**Variables:**
- UPPERCASE_WITH_UNDERSCORES for all shell variables: `CONTAINER_NAME`, `IMAGE`, `PORT`, `CONFIG_DIR`, `SCRIPT_DIR`, `EXTRA_ARGS`
- Configuration variables at script top: ports (e.g., `PORT=8020`), image names, container names
- Temporary/boolean variables use descriptive names: `OLLAMA_RUNNING`, `VLLM_RUNNING`, `VLLM_MODEL`, `OPENAI_KEY`
- Variables capturing paths use underscore case: `CONFIG_DIR`, `ENV_FILE`, `CONFIG_FILE`, `MINICONDA_DIR`, `HOME`, `PWD`

**Functions:**
- No explicit functions defined; scripts structured as sequential command execution with inline error handling
- Shell inline operations for common tasks rather than function definitions

## Code Style

**Formatting:**
- Shebang always: `#!/usr/bin/env bash` at line 1
- Error handling: `set -e` at top for exit-on-error; some scripts use `set -euo pipefail` for stricter mode (see `dgx-global-base-setup.sh`)
- Line length: No specific limit observed; practical wrapping at docker run commands (60-80 chars before continuation)
- Indentation: 2 spaces for command continuations (docker run, heredoc content)

**Linting:**
- ShellCheck directives observed: `# shellcheck disable=SC1090` for sourcing files without validation
- Most scripts pass default ShellCheck without suppressions
- Quoting convention: all variable references quoted (`"${VAR}"`) to prevent word splitting

## Import Organization

**Not applicable** - Shell scripts do not use import statements. Source operations occur inline:
```bash
# shellcheck disable=SC1090
source "$HOME/.bashrc" || true
```

**Sourcing pattern:**
- Guard with `|| true` to prevent exit on source failure
- Only used in `dgx-global-base-setup.sh` for sourcing `.bashrc` to apply newly added configurations
- Suppress ShellCheck warnings for dynamic sourcing with explicit disable comment

## Error Handling

**Patterns:**
- **Exit-on-error mode:** `set -e` used in all scripts as default safety mechanism
- **Strict mode:** `set -euo pipefail` in `dgx-global-base-setup.sh` for maximum safety (no undefined vars, pipefail)
- **Optional operations:** Use `|| true` suffix to continue on error: `docker rm -f "$CONTAINER_NAME" 2>/dev/null` or `docker start "$CONTAINER_NAME" || docker run ...`
- **Graceful fallback chains:** `setup-litellm-config.sh` attempts docker run with `--env-file` flag, falls back to run without it (lines 70-77)
- **Exit codes:** Explicit `exit 0` or `exit 1` used for status signaling; missing exit codes default to previous command's exit status

**Error suppression:**
- Redirect stderr to `/dev/null` for operations that may fail benignly: `docker ps 2>/dev/null`, `mkdir -p ... 2>/dev/null`
- Guard existence checks with `-f` (files) or `-d` (directories): `[ -f "$FILE" ] && ...` or `[ ! -f "$FILE" ] && ...`

## Logging

**Framework:** `echo` and `printf` exclusively; no structured logging framework

**Patterns:**
- **Status messages:** Plain `echo` for progress: `echo "Creating LiteLLM container..."`
- **Section headers:** `echo` with separator lines (equals/dashes):
  ```bash
  echo "========================================"
  echo " LiteLLM Proxy"
  echo "========================================"
  ```
- **Information blocks:** Echo variable-interpolated messages:
  ```bash
  echo "  Model:    ${MODEL}"
  echo "  API:      http://localhost:${PORT}/v1"
  ```
- **User instructions:** Multi-line usage examples via `echo` or heredoc cat:
  ```bash
  cat << 'GUIDE'
  [multiline instructions]
  GUIDE
  ```
- **Streaming logs:** `docker logs -f "$CONTAINER_NAME"` at script exit to watch service startup

## Comments

**When to Comment:**
- Header comments at line 1-3: describe script purpose, usage, examples
- Inline comments before logical sections (prefixed with `#` on separate line)
- Section dividers: `# --- [Section Name] ---` used in `setup-litellm-config.sh`
- Conditional explanations: brief comments on logic branches: `# Fall back to config file if no model argument`

**JSDoc/TSDoc:**
- Not applicable; shell scripts use no documentation generation

**Example from `start-vllm.sh` (lines 1-6):**
```bash
#!/usr/bin/env bash
# vLLM OpenAI-compatible inference server
# Usage: start-vllm.sh [model_name] [extra_args...]
#   If no model_name is given, reads from ~/.vllm-model
# Example: start-vllm.sh meta-llama/Llama-3.1-8B-Instruct
# Example: start-vllm.sh unsloth/Llama-3.1-8B-Instruct --max-model-len 4096
```

## Argument Handling

**Parameter passing:**
- First positional argument captured as `MODEL="${1:-}"` (empty string default)
- Remaining arguments shifted and collected: `shift 2>/dev/null || true` then `EXTRA_ARGS="$*"`
- Optional arguments with defaults: `TAG="${1:-latest}"` uses bash parameter expansion

**Validation:**
- Mandatory parameters checked with string test: `if [ -z "$MODEL" ]; then exit 1; fi`
- Fallback to config files: `if [ ! -f "$HOME/.vllm-model" ]` pattern in `start-vllm.sh`

## Docker Integration Patterns

**Container management:**
- Variables for reusability: `CONTAINER_NAME`, `IMAGE`, `PORT` defined at script start
- Status checks: `docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"` to detect running containers
- Cleanup: `docker rm -f "$CONTAINER_NAME" 2>/dev/null` for safe removal
- Idempotent checks: conditional logic to start existing or create new containers (see `start-litellm.sh`, `start-open-webui.sh`)

**Volume mounting:**
- Host directories created before mount: `mkdir -p "$HOME/data/raw" "$HOME/data/processed" ...`
- Model cache shared across containers: `-v "$HOME/.cache/huggingface:/root/.cache/huggingface"`
- Configuration mounted read-only: `-v "file:/path" -v "file:/path:ro"`
- Workspace mounts: `-v "${PWD}:/workspace" -w /workspace` for interactive containers

**Environment variables:**
- Passed via `-e VAR=value` flags for individual settings
- Bulk via `--env-file "$FILE"` with `.env` files (see `start-litellm.sh`)
- Conditional mounting: `--env-file ... 2>/dev/null ||` pattern allows missing env file

## Special Patterns

**Polling/Readiness checks:**
- `setup-litellm-config.sh`: Curl polling with retry loop to detect service availability:
  ```bash
  while IFS= read -r model; do
      [ -n "$model" ] && OLLAMA_MODELS+=("$model")
  done < <(curl -sf http://localhost:11434/api/tags 2>/dev/null | python3 -c "...")
  ```

**Python inline execution:**
- Python one-liners embedded in docker run bash commands for JSON parsing (see `setup-litellm-config.sh` lines 37-44)
- Parse JSON responses from service APIs via `python3 -c "import json; ..."`

**Idempotency:**
- Guard blocks check existence before modifying state: `if [ -d "$MINICONDA_DIR" ]; then ... else ... fi`
- Append patterns for `.bashrc` check for presence before adding: `if ! grep -q "conda init bash" "$HOME/.bashrc" 2>/dev/null; then ...`
- Safe rm with -f flag and stderr suppression for cleanup

---

*Convention analysis: 2026-03-19*
