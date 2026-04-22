# sparkrun-claude

Route Anthropic's **Claude Code** through a sparkrun/LiteLLM proxy so it
infers against local (vLLM / SGLang / llama.cpp / Ollama) models instead
of `api.anthropic.com`.

This directory is a self-contained, portable package.  It does not rely
on hard-coded paths or IPs — every machine-specific value is either
discovered at runtime or overridable via environment variable.

## What's in here

| File | Purpose |
|------|---------|
| `sparkrun-claude`  | Main wrapper (sourced, not executed).  Discovers proxy, lists models, applies env vars, launches `claude`. |
| `proxy-filter.py`  | Local SSE rewriter — runs on `127.0.0.1:11435` during a session and fixes two LiteLLM anthropic_messages bugs that would otherwise make Claude Code render empty responses. |
| `.gitignore`       | Stops runtime state (`.last-endpoint`, `filter.log`) from being committed. |

## How a request flows

```
Claude Code (your machine)
    │  POST /v1/messages  (Anthropic Messages API, streaming SSE)
    ▼
proxy-filter.py  (127.0.0.1:11435 — started by sparkrun-claude)
    │  dedups duplicate message_start events
    │  drops empty `thinking` content blocks, renumbers indices
    ▼
sparkrun / LiteLLM  (http://<dgx-host>:4000)
    │  translates Anthropic Messages → OpenAI Chat Completions
    ▼
vLLM / SGLang / Ollama / etc.  (backend inference engine)
```

## Why the filter is needed

LiteLLM's `/v1/messages` passthrough (tested against LiteLLM versions
shipping with sparkrun as of this writing) emits two malformed SSE
patterns that break Claude Code's streaming parser:

1. **Duplicate `message_start`** — the same `message_start` event is
   emitted twice in a row.  Per the Anthropic streaming spec, each
   message has exactly one.  Claude Code's state machine rejects the
   second and drops every subsequent event.

2. **Empty `thinking` content block** — reasoning models (Qwen3.x,
   DeepSeek-R1, o1-style) produce `reasoning_content` which LiteLLM
   maps to a `thinking` content block.  In streaming mode, LiteLLM
   emits `content_block_start` with `thinking: ""` and immediately
   `content_block_stop` without any intervening `thinking_delta`
   events.  Claude Code treats this as an invalid block and discards
   the whole message — the user sees nothing.

The filter detects both patterns in flight and rewrites the stream so
Claude Code sees a well-formed response.  It is dynamic: filled
thinking blocks (a model that actually streams `thinking_delta` events
with real reasoning text) pass through untouched.

## Discovery order

`sparkrun-claude` locates a proxy in this order, stopping at the first
that responds to `GET /health` or `GET /v1/models`:

1. `.last-endpoint` — URL cached from the previous successful session
2. `127.0.0.1:<SPARKRUN_PROXY_PORT>` — covers locally-hosted LiteLLM
3. ARP cache parallel scan — every host currently in the ARP table
4. `/24` subnet parallel scan — every address in the local subnet
5. Manual prompt — `"Enter proxy address (e.g. 192.168.1.100:4000):"`

## Environment variables (all optional)

| Variable                    | Default           | Purpose |
|-----------------------------|-------------------|---------|
| `SPARKRUN_PROXY_PORT`       | `4000`            | Port the upstream LiteLLM listens on |
| `SPARKRUN_FILTER_PORT`      | `11435`           | Port the local filter binds to |
| `SPARKRUN_FILTER_DEBUG`     | unset             | Set to `1` to log each filter decision to `filter.log` |
| `SPARKRUN_MASTER_KEY`       | `sparkrun-local`  | Auth token if the proxy was started with `--master-key` |
| `SPARKRUN_MAX_TOKENS`       | `32768`           | Value exported as `CLAUDE_CODE_MAX_OUTPUT_TOKENS` — reasoning models burn output tokens on hidden thinking; 4K defaults starve them |

## Files created at runtime (all gitignored)

- `.last-endpoint` — last successfully contacted proxy URL
- `filter.log`     — stdout/stderr from the filter subprocess

## Session lifecycle

On launch:
- All existing Anthropic env vars are saved (using an `UNSET_MARKER`
  sentinel so "unset" is distinguishable from "set to empty").
- `ANTHROPIC_API_KEY` is unset (it would otherwise win over
  `ANTHROPIC_AUTH_TOKEN`).
- `ANTHROPIC_BASE_URL` is pointed at the filter.
- `DISABLE_TELEMETRY=1` and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`
  are exported so no outbound calls leak to Anthropic during the
  session.
- The filter subprocess is spawned, the wrapper polls its log for the
  "ready" marker, and `claude --dangerously-skip-permissions --model
  <selected>` is exec'd.

On exit:
- The filter is SIGTERM'd; if it doesn't exit in ~1 s it's SIGKILL'd.
- Every saved env var is restored to its original state (unset vars
  stay unset; set vars get their original value back).
