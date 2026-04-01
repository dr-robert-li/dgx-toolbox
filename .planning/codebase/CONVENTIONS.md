# Coding Conventions

**Analysis Date:** 2026-04-01

## Naming Patterns

**Files (Python):**
- Use `snake_case.py` for all Python modules: `redactor.py`, `sliding_window.py`, `rail_loader.py`
- Test files: `test_<module>.py` in a dedicated `tests/` directory: `harness/tests/test_auth.py`, `harness/tests/test_pii.py`
- Package init files: `__init__.py` in every Python package directory

**Files (Shell):**
- Use `kebab-case.sh` for all shell scripts: `start-vllm.sh`, `test-config.sh`, `run-all.sh`
- Prefix launcher scripts with `start-`: `start-vllm.sh`, `start-litellm.sh`, `start-open-webui.sh`
- Prefix build scripts with `-build`: `eval-toolbox-build.sh`, `data-toolbox-build.sh`
- Sync-mode variants append `-sync`: `start-vllm-sync.sh`, `start-litellm-sync.sh`

**Functions (Python):**
- Use `snake_case`: `verify_api_key()`, `load_tenants()`, `redact()`, `compute_priority()`
- Private/internal functions prefixed with `_`: `_regex_redact()`, `_extract_triggering_rail()`
- Async functions use the same naming (no `async_` prefix): `async def check_input()`

**Functions (Shell):**
- Use `snake_case`: `ms_log()`, `ms_die()`, `check_cold_mounted()`, `validate_cold_fs()`
- Modelstore functions prefixed with `ms_`: `ms_log()`, `ms_die()`
- Top-level lib functions unprefixed: `get_ip()`, `is_running()`, `ensure_container()`

**Variables (Python):**
- Module-level private constants use `_UPPER_SNAKE_CASE`: `_CONFIG_DIR`, `_LITELLM_BASE`, `_OPERATOR_MAP`
- Public constants use `UPPER_SNAKE_CASE`: `STRICTNESS_ENTITIES`, `INJECTION_PATTERNS`
- Local variables use `snake_case`: `trace_store`, `db_path`, `rail_filter`

**Variables (Shell):**
- Constants in `UPPER_SNAKE_CASE`: `PORT`, `CONTAINER_NAME`, `IMAGE`, `MODELSTORE_CONFIG`
- Local variables in `lower_snake_case`: `local cold_path`, `local fstype`

**Classes (Python):**
- Use `PascalCase`: `TenantConfig`, `TraceStore`, `GuardrailEngine`, `SlidingWindowLimiter`
- Pydantic models use `PascalCase`: `TenantConfig`, `TenantsFile`, `RailConfig`
- Dataclass-style types: `GuardrailDecision`, `RailResult`

## Code Style

**Formatting (Python):**
- No explicit formatter config (no ruff, black, or pyproject.toml formatting sections)
- 4-space indentation throughout
- Line length generally kept under 120 characters
- Double quotes for strings (consistent across all Python files)
- Use `from __future__ import annotations` at top of modules that use `|` union types: `harness/traces/store.py`, `harness/proxy/litellm.py`

**Formatting (Shell):**
- ShellCheck enforced at `--severity=error` in CI (`.github/workflows/test.yml`)
- Exclude `SC1087` from ShellCheck
- 2-space indentation for shell scripts
- `set -euo pipefail` for production scripts, `set -uo pipefail` (no `-e`) for test scripts
- Use `#!/usr/bin/env bash` shebang for all shell scripts

**Linting:**
- ShellCheck for all `.sh` files (CI job: `shellcheck`), excludes `karpathy-autoresearch/` directory
- Bash syntax check: `bash -n` for all `.sh` files (CI job: `bash-syntax`)
- No Python linter config (no ruff, flake8, pylint, or mypy configured)
- Secrets scanning in CI: regex patterns for API keys from known providers

## Import Organization

**Python import order:**
1. `from __future__ import annotations` (when used)
2. Standard library imports: `os`, `json`, `re`, `asyncio`, `pathlib`
3. Third-party imports: `pytest`, `httpx`, `fastapi`, `pydantic`, `yaml`
4. Local imports: `from harness.config.loader import TenantConfig`

**Python import style:**
- Prefer `from X import Y` over `import X` for specific symbols
- Module-level imports at top of file
- Delayed imports inside functions/lifespan when needed for startup ordering: see `harness/main.py` lines 46-73

**Shell source organization:**
- Scripts source shared libs at top: `source "${MODELSTORE_LIB}/common.sh"`
- Use `shellcheck source=` directives for static analysis: `# shellcheck source=../lib/config.sh`
- Top-level `lib.sh` provides shared utilities; modelstore has its own `lib/` directory

**Path Aliases:**
- None used (no pyproject.toml path aliases, no TypeScript)

## Error Handling

**Python patterns:**
- Raise `ValueError` for configuration/validation errors: `harness/config/loader.py` lines 46-54
- Raise `HTTPException` for API errors with status code and detail message: `harness/auth/bearer.py` line 29
- Wrap external errors with `from exc` for chaining: `raise ValueError(...) from exc`
- Optional features degrade gracefully with try/except: `harness/main.py` line 68 catches `FileNotFoundError` for optional CAI config
- `# noqa: F401` and `# noqa: E402` used for intentional import side effects and late imports

**Shell patterns:**
- `ms_die "message"` for fatal errors (logs to stderr, exits 1): `modelstore/lib/common.sh`
- `set -euo pipefail` ensures scripts fail fast on errors
- Temp directory cleanup with `trap 'rm -rf "$TMPDIR"' EXIT`
- Guard conditions before destructive operations: check if container running before starting

## Logging

**Python:**
- No structured logging framework; uses print/stderr implicitly through FastAPI
- Module docstrings serve as documentation for purpose

**Shell:**
- `ms_log()` function logs to stderr with `[modelstore]` prefix: `modelstore/lib/common.sh` line 14
- `ms_die()` function logs error to stderr and exits: `modelstore/lib/common.sh` line 19
- Banner output via `print_banner()` function in `lib.sh` for service startup messages

## Comments

**Module docstrings:**
- Every Python module starts with a triple-quoted docstring describing purpose: `"""PII redaction using regex pre-pass + Microsoft Presidio NER."""`
- Every test module starts with a docstring referencing the requirement IDs covered: `"""Tests for GATE-02: Auth via API key..."""`

**Section dividers:**
- Use `# ---------------------------------------------------------------------------` comment blocks to separate logical sections within files
- Section headers follow the divider: `# Fixtures`, `# Input rail tests`, `# Edge cases`

**Shell script headers:**
- Every `.sh` file starts with a comment describing purpose: `# modelstore/lib/common.sh - Shared safety and logging functions`
- Usage documentation in script header comments for launcher scripts: `# Usage: start-vllm.sh [model_name] [extra_args...]`

**Inline comments:**
- Used sparingly for non-obvious logic
- Comments explain "why" not "what"

## Function Design

**Size:**
- Functions generally kept small (under 30 lines for Python, under 20 lines for Shell)
- Larger functions broken into private helpers: `_regex_redact()` called by `redact()`

**Parameters (Python):**
- Use type hints on all function signatures: `def redact(text: str, strictness: str = "balanced") -> str:`
- Use keyword arguments with defaults for optional params
- Pydantic `BaseModel` for structured config objects: `TenantConfig`, `RailConfig`

**Parameters (Shell):**
- Use `local` for all function-scoped variables: `local cold_path="$1"`
- Document parameters in comments: `# Usage: check_space <destination_path> <required_bytes>`

**Return values (Python):**
- Use `| None` union types for nullable returns: `-> dict | None`
- Use type hints for return types consistently

## Module Design

**Exports (Python):**
- Each package has an `__init__.py` (mostly empty for namespace)
- Specific imports from modules, not wildcard

**Barrel files:**
- Not used; imports reference specific modules directly

**Package structure (Python):**
- Feature-oriented packages under `harness/`: `auth/`, `config/`, `pii/`, `guards/`, `traces/`, `proxy/`, `critique/`, `eval/`, `redteam/`, `hitl/`
- Each package contains implementation module(s) and `__init__.py`
- `__main__.py` for CLI entry points: `harness/critique/__main__.py`, `harness/eval/__main__.py`, `harness/hitl/__main__.py`

**Shell module structure:**
- `lib/` for shared functions: `modelstore/lib/common.sh`, `modelstore/lib/config.sh`
- `cmd/` for command implementations: `modelstore/cmd/init.sh`, `modelstore/cmd/status.sh`
- `test/` for test scripts: `modelstore/test/test-config.sh`
- `cron/` for scheduled jobs: `modelstore/cron/migrate_cron.sh`

## Configuration Conventions

**Environment variables:**
- Env vars read with fallback defaults: `os.environ.get("HARNESS_CONFIG_DIR", default_path)`
- Config paths: `HARNESS_CONFIG_DIR`, `LITELLM_BASE_URL`, `HARNESS_DATA_DIR`
- Never hardcode secrets; use env vars or config files

**YAML configuration:**
- Tenant config in `tenants.yaml` validated by Pydantic: `harness/config/loader.py`
- Rail config in `rails/rails.yaml` validated by custom loader: `harness/config/rail_loader.py`
- Constitution config in `constitution.yaml`: `harness/config/constitution.yaml`

**JSON configuration (Shell):**
- Modelstore config stored as JSON at `MODELSTORE_CONFIG` path
- Written with `write_config()`, read with `config_read()` using `jq`
- Config files set to `chmod 600` for security: `modelstore/test/test-config.sh` line 89

---

*Convention analysis: 2026-04-01*
