#!/usr/bin/env python3
"""
sparkrun-claude local filter proxy.

Problem: LiteLLM's /v1/messages anthropic_messages passthrough emits a
malformed SSE stream that breaks Claude Code's parser:
  1. Duplicate `message_start` events (same message ID, emitted twice)
  2. An empty `thinking` content block with no `thinking_delta` events
     (LiteLLM doesn't forward reasoning_content in streaming mode)

Either issue makes Claude Code silently drop the entire response.

Fix: run this tiny proxy on localhost.  It forwards every HTTP method
verbatim to the real upstream (the sparkrun/LiteLLM proxy on the DGX),
with one exception — for text/event-stream responses it:
  • drops the second `message_start`
  • drops empty `thinking` content blocks and renumbers following indices

Environment:
  SPARKRUN_UPSTREAM       Upstream base URL (e.g. http://<dgx-host>:4000)
  SPARKRUN_FILTER_PORT    Local listen port (default 11435)
  SPARKRUN_FILTER_DEBUG   If set to 1, logs each filtered event to stderr
"""

import http.server
import json
import os
import socketserver
import sys
import urllib.error
import urllib.request

UPSTREAM = os.environ.get("SPARKRUN_UPSTREAM", "").rstrip("/")
LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = int(os.environ.get("SPARKRUN_FILTER_PORT", "11435"))
DEBUG = os.environ.get("SPARKRUN_FILTER_DEBUG") == "1"

if not UPSTREAM:
    sys.stderr.write("SPARKRUN_UPSTREAM env var is required\n")
    sys.exit(2)


def dbg(msg: str) -> None:
    if DEBUG:
        sys.stderr.write(f"[filter] {msg}\n")
        sys.stderr.flush()


class FilterHandler(http.server.BaseHTTPRequestHandler):
    # Silence default access log
    def log_message(self, fmt, *args):
        return

    def _forward(self):
        body = None
        cl = self.headers.get("Content-Length")
        if cl:
            body = self.rfile.read(int(cl))

        # Copy request headers, stripping hop-by-hop
        fwd_headers = {}
        for k, v in self.headers.items():
            if k.lower() in ("host", "content-length", "connection", "accept-encoding"):
                continue
            fwd_headers[k] = v

        url = UPSTREAM + self.path
        req = urllib.request.Request(
            url, data=body, method=self.command, headers=fwd_headers
        )

        try:
            resp = urllib.request.urlopen(req, timeout=600)
        except urllib.error.HTTPError as e:
            resp = e
        except Exception as e:
            self.send_response(502)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            try:
                self.wfile.write(f"filter upstream error: {e}".encode())
            except BrokenPipeError:
                pass
            return

        content_type = resp.headers.get("Content-Type", "")
        is_sse = "text/event-stream" in content_type.lower()

        # Send response line + headers (drop hop-by-hop)
        self.send_response(resp.status)
        for k, v in resp.headers.items():
            if k.lower() in (
                "content-length",
                "transfer-encoding",
                "connection",
                "content-encoding",
            ):
                continue
            self.send_header(k, v)
        self.end_headers()

        if not is_sse:
            try:
                while True:
                    chunk = resp.read(8192)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except BrokenPipeError:
                pass
            return

        # ── SSE filter state machine ───────────────────────────────────
        #
        # Two dynamic behaviours:
        #   (a) Dedup `message_start` — LiteLLM sometimes emits it twice,
        #       always wrong per Anthropic spec.
        #   (b) Drop empty thinking blocks — a thinking content block that
        #       never received a non-empty `thinking_delta` before its
        #       `content_block_stop` is dropped and subsequent block
        #       indices are renumbered down by one.
        #
        # Filled thinking blocks (with real `thinking_delta` content from
        # a capable model) pass through untouched.  Non-thinking block
        # types (text, tool_use, etc.) always pass through.
        #
        # To decide per-block, we BUFFER every thinking content block
        # (start + all deltas) and flush at content_block_stop:
        #   • had any `thinking_delta` with non-empty text  → flush all
        #   • otherwise (LiteLLM's empty-thinking bug)       → drop all

        seen_message_start = False
        # orig_idx → out_idx  (only recorded for blocks we emit)
        index_map: dict[int, int] = {}
        next_out_idx = 0

        # Buffering state for the current in-flight thinking block.
        # None when not buffering.
        buffering_idx: int | None = None
        buffered_events: list[str] = []  # raw event strings (with trailing data)
        buffered_had_content = False

        def parse_event(raw: str):
            ev_name = None
            data_str = None
            for line in raw.split("\n"):
                if line.startswith("event:"):
                    ev_name = line[6:].strip()
                elif line.startswith("data:"):
                    data_str = line[5:].strip()
            return ev_name, data_str

        def emit_event(ev_name: str, data_obj):
            out = f"event: {ev_name}\ndata: {json.dumps(data_obj)}\n\n"
            self.wfile.write(out.encode())
            self.wfile.flush()

        def emit_raw(raw: str):
            self.wfile.write((raw + "\n\n").encode())
            self.wfile.flush()

        def flush_buffer_with_remap(orig_idx: int):
            """Flush buffered thinking block, renumbering to next_out_idx."""
            nonlocal next_out_idx
            out_idx = next_out_idx
            index_map[orig_idx] = out_idx
            next_out_idx += 1
            for raw in buffered_events:
                ev, ds = parse_event(raw)
                if ds:
                    try:
                        d = json.loads(ds)
                        if d.get("index") == orig_idx:
                            d["index"] = out_idx
                        self.wfile.write(
                            f"event: {ev}\ndata: {json.dumps(d)}\n\n".encode()
                        )
                    except json.JSONDecodeError:
                        self.wfile.write((raw + "\n\n").encode())
                else:
                    self.wfile.write((raw + "\n\n").encode())
            self.wfile.flush()

        buf = b""
        try:
            while True:
                chunk = resp.read(4096)
                if not chunk and not buf:
                    break
                if chunk:
                    buf += chunk

                # Process complete events
                while b"\n\n" in buf:
                    raw_bytes, buf = buf.split(b"\n\n", 1)
                    raw = raw_bytes.decode("utf-8", errors="replace")
                    ev_name, data_str = parse_event(raw)

                    # 1. Duplicate message_start → drop
                    if ev_name == "message_start":
                        if seen_message_start:
                            dbg("drop duplicate message_start")
                            continue
                        seen_message_start = True
                        emit_raw(raw)
                        continue

                    # 2. content_block_start — maybe start buffering
                    if ev_name == "content_block_start" and data_str:
                        try:
                            d = json.loads(data_str)
                        except json.JSONDecodeError:
                            emit_raw(raw)
                            continue
                        cb = d.get("content_block", {})
                        orig_idx = d.get("index")
                        if cb.get("type") == "thinking":
                            # Buffer until we know if deltas arrive
                            buffering_idx = orig_idx
                            buffered_events = [raw]
                            buffered_had_content = bool(cb.get("thinking"))
                            dbg(f"buffer thinking block idx={orig_idx}")
                            continue
                        # Non-thinking block → emit with remapped index
                        index_map[orig_idx] = next_out_idx
                        d["index"] = next_out_idx
                        next_out_idx += 1
                        emit_event(ev_name, d)
                        continue

                    # 3. content_block_delta — buffer or remap
                    if ev_name == "content_block_delta" and data_str:
                        try:
                            d = json.loads(data_str)
                        except json.JSONDecodeError:
                            emit_raw(raw)
                            continue
                        orig_idx = d.get("index")
                        if buffering_idx is not None and orig_idx == buffering_idx:
                            # Track whether any real thinking content arrived
                            delta = d.get("delta", {})
                            if delta.get("type") == "thinking_delta":
                                if delta.get("thinking"):
                                    buffered_had_content = True
                            # Also consider signature_delta as meaningful
                            elif delta.get("type") == "signature_delta":
                                buffered_had_content = True
                            buffered_events.append(raw)
                            continue
                        if orig_idx in index_map:
                            d["index"] = index_map[orig_idx]
                            emit_event(ev_name, d)
                            continue
                        # Unknown index — pass through (defensive)
                        emit_raw(raw)
                        continue

                    # 4. content_block_stop — flush or drop buffer, else remap
                    if ev_name == "content_block_stop" and data_str:
                        try:
                            d = json.loads(data_str)
                        except json.JSONDecodeError:
                            emit_raw(raw)
                            continue
                        orig_idx = d.get("index")
                        if buffering_idx is not None and orig_idx == buffering_idx:
                            if buffered_had_content:
                                dbg(
                                    f"flush thinking block idx={orig_idx} "
                                    f"({len(buffered_events)} buffered events)"
                                )
                                flush_buffer_with_remap(orig_idx)
                                # Now emit the stop event with remapped index
                                d["index"] = index_map[orig_idx]
                                emit_event(ev_name, d)
                            else:
                                dbg(
                                    f"drop empty thinking block idx={orig_idx} "
                                    f"({len(buffered_events)} discarded)"
                                )
                            buffering_idx = None
                            buffered_events = []
                            buffered_had_content = False
                            continue
                        if orig_idx in index_map:
                            d["index"] = index_map[orig_idx]
                            emit_event(ev_name, d)
                            continue
                        emit_raw(raw)
                        continue

                    # Default: passthrough any other event
                    emit_raw(raw)

                if not chunk:
                    break

            # Upstream closed while we still had a buffered block.  Safest
            # to drop it — an unclosed thinking block with no content is
            # exactly the bug we guard against.
            if buffering_idx is not None:
                dbg(
                    f"upstream closed with unbuffered thinking block "
                    f"idx={buffering_idx} — dropped"
                )
        except BrokenPipeError:
            dbg("client disconnected")
            return

    # Route every HTTP method through _forward
    do_GET = _forward
    do_POST = _forward
    do_PUT = _forward
    do_DELETE = _forward
    do_PATCH = _forward
    do_OPTIONS = _forward
    do_HEAD = _forward


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    server = ThreadedHTTPServer((LISTEN_HOST, LISTEN_PORT), FilterHandler)
    # Signal readiness on stdout — the bash wrapper polls for this line
    print(f"[filter] ready {LISTEN_HOST}:{LISTEN_PORT} -> {UPSTREAM}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
