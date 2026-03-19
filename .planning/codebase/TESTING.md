# Testing Patterns

**Analysis Date:** 2026-03-19

## Test Framework

**Status:** Not applicable

This codebase contains **zero automated tests**. The project is a collection of shell scripts for deploying and managing ML/AI services on NVIDIA DGX Spark hardware. Testing is exclusively manual/operational.

## Test Organization

**Manual verification approach:**

Scripts are designed to be **self-verifying** through:
1. **Exit-on-error mode:** `set -e` ensures any failing command halts execution
2. **Status messages:** `echo` output at each stage allows operator to verify progress
3. **Final logging output:** `docker logs -f` at script completion allows real-time inspection of service startup

**Example from `start-vllm.sh` (lines 61-78):**
```bash
echo ""
echo "========================================"
echo " vLLM Server"
echo "========================================"
echo "  Model:    ${MODEL}"
echo "  API:      http://localhost:${PORT}/v1"
echo "  LAN:      http://${IP}:${PORT}/v1"
echo "  Models:   http://localhost:${PORT}/v1/models"
echo ""
echo "  Usage:    curl http://localhost:${PORT}/v1/chat/completions \\"
# ... curl example ...
echo ""
echo "  Stop:     docker stop vllm && docker rm vllm"
echo "========================================"
echo ""
echo "Streaming logs (Ctrl+C to detach, server keeps running)..."
docker logs -f "$CONTAINER_NAME"
```

This pattern provides:
- **Visibility:** Clear state before running service
- **Usability:** Example curl commands for immediate testing
- **Debugging:** Live logs streaming to stdout for troubleshooting

## Error Handling and Safety

**No formal test suite; instead, safety is enforced through script design:**

### Shell Strictness
```bash
# Default in most scripts
set -e

# Maximum strictness in system-wide setup (dgx-global-base-setup.sh)
set -euo pipefail
```

**What this means:**
- `-e`: Exit immediately if any command fails (prevents cascade failures)
- `-u`: Exit if undefined variable is used (catches typos like `${CONTANER_NAME}`)
- `-o pipefail`: Pipeline fails if any command in pipe fails (prevents silent data loss)

### Graceful Degradation
Some operations designed to fail safely:

**Example from `setup-litellm-config.sh` (lines 70-77):**
```bash
docker run -d ... \
    --env-file "$CONFIG_DIR/.env" 2>/dev/null \
    --restart unless-stopped \
    "$IMAGE" \
|| docker run -d ... \
    # Retry without --env-file
    "$IMAGE" ...
```

This fallback chain allows:
1. Try running with .env file if it exists
2. If that fails (missing file), retry without it
3. Exit with success if either attempt succeeds

### Optional Operations
Commands that should not fail the script:

```bash
# Example from setup-litellm-config.sh (line 66)
--env-file "$CONFIG_DIR/.env" 2>/dev/null

# Example from start-vllm.sh (line 44)
docker rm -f "$CONTAINER_NAME" 2>/dev/null
```

Stderr redirected to `/dev/null` allows cleanup operations to fail silently without halting the script.

## Validation Patterns

**Input validation:**

**Example from `start-vllm.sh` (lines 17-35):**
```bash
# Check for required model parameter
if [ -z "$MODEL" ] && [ -f "$HOME/.vllm-model" ]; then
    MODEL=$(head -1 "$HOME/.vllm-model" | xargs)
fi

# Fail with usage if model still missing
if [ -z "$MODEL" ]; then
    echo "Usage: start-vllm.sh [model_name] [extra_args...]"
    # ... detailed usage examples ...
    exit 1
fi
```

This pattern:
1. Checks parameter is provided or readable from fallback file
2. Provides clear usage message if validation fails
3. Examples show exactly how to invoke correctly

**State validation:**

**Example from `start-open-webui.sh` (lines 10-17):**
```bash
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "Open-WebUI is already running"
    else
        echo "Starting existing Open-WebUI container..."
        docker start "$CONTAINER_NAME"
    fi
else
    echo "Creating Open-WebUI container..."
    docker run -d ...
fi
```

Validates:
1. Container exists (in any state)
2. Container is running (if exists)
3. Chooses appropriate action: attach, start existing, or create new

## Service Health Checks

**Readiness polling:**

**Example from `unsloth-studio.sh` (lines 72-90):**
```bash
(
    for i in $(seq 1 360); do
        # Check if container is still alive
        if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            echo ""
            echo "Container exited unexpectedly."
            exit 1
        fi
        # Check if service responds to HTTP
        if curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT}" 2>/dev/null | grep -q "200\|302\|301"; then
            echo ""
            echo "Unsloth Studio is ready!"
            xdg-open "http://localhost:${PORT}" 2>/dev/null || true
            exit 0
        fi
        sleep 5
    done
    echo ""
    echo "Studio did not respond within 30 minutes."
) &
```

This pattern:
1. **Crash detection:** Polls container status (fails if exited unexpectedly)
2. **Readiness detection:** HTTP status code polling (200/301/302 indicate readiness)
3. **Timeout:** 360 iterations × 5 seconds = 30 minute max wait
4. **Background execution:** Runs polling in subshell so logs continue streaming
5. **User feedback:** Opens browser when ready or reports timeout

## Service Detection

**Capabilities detection:**

**Example from `setup-litellm-config.sh` (lines 22-29):**
```bash
OLLAMA_RUNNING=false
VLLM_RUNNING=false

if curl -sf http://localhost:11434/api/version >/dev/null 2>&1; then
    OLLAMA_RUNNING=true
fi

if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^vllm$"; then
    VLLM_RUNNING=true
    VLLM_MODEL=$(docker inspect vllm --format '{{join .Args " "}}' 2>/dev/null | grep -oP '(?<=--model )\S+' || echo "")
fi
```

Determines:
- Ollama availability via API health check
- vLLM availability via Docker container check
- vLLM model name via container inspect + regex extraction

**Model detection:**

```bash
# From setup-litellm-config.sh (lines 35-44)
while IFS= read -r model; do
    [ -n "$model" ] && OLLAMA_MODELS+=("$model")
done < <(curl -sf http://localhost:11434/api/tags 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for m in data.get('models', []):
        print(m['name'])
except: pass
" 2>/dev/null)
```

Parses JSON API response to extract available models, handles parse failures gracefully.

## Coverage

**No coverage metrics exist.** Testing is operator-driven:

1. **Pre-flight checks:** Script validates preconditions (model specified, config files exist)
2. **Execution transparency:** All commands and their output visible to operator
3. **Self-reporting:** Services emit health status messages and API examples
4. **Manual validation:** Operator uses provided curl examples to test APIs

## Documentation for Testing

Scripts include embedded testing guidance:

**Example from `start-vllm.sh` (lines 70-73):**
```bash
echo "  Usage:    curl http://localhost:${PORT}/v1/chat/completions \\"
echo "              -H 'Content-Type: application/json' \\"
echo "              -d '{\"model\": \"${MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}]}'"
```

**Example from `ngc-quickstart.sh`:** Full guide printed to stdout on container entry showing:
- GPU verification commands
- Pre-installed package examples
- Common workflows with working code samples

---

*Testing analysis: 2026-03-19*
