"""Gradio HITL review dashboard — two-panel master-detail layout.

Connects to the harness API via sync httpx.Client.  Launch via:
    python -m harness.hitl ui --api-url http://localhost:8080 --api-key sk-test
"""
from __future__ import annotations

import difflib
import json
from typing import Any

import httpx


def _extract_triggering_rail_inline(guardrail_decisions: dict) -> str | None:
    """Return the rail name from the all_results entry closest to threshold.

    Mirrors harness.traces.store._extract_triggering_rail for inline use
    without importing the async store module.
    """
    if isinstance(guardrail_decisions, list):
        all_results = guardrail_decisions
    else:
        all_results = guardrail_decisions.get("all_results", [])
    best: str | None = None
    best_distance = float("inf")
    for result in all_results:
        score = result.get("score", 0)
        threshold = result.get("threshold", 1.0)
        if score > 0:
            distance = threshold - score
            if distance < best_distance:
                best_distance = distance
                best = result.get("rail_name") or result.get("rail")
    return best


def _action_taken(item: dict) -> str:
    """Derive human-readable action from guardrail_decisions dict."""
    gd = item.get("guardrail_decisions") or {}
    if isinstance(gd, str):
        try:
            gd = json.loads(gd)
        except (json.JSONDecodeError, TypeError):
            gd = {}
    status_code = item.get("status_code", 200)
    refusal_event = item.get("refusal_event", 0)
    # guardrail_decisions may be a list (from trace JSON) or a dict with 'all_results'
    if isinstance(gd, list):
        all_results = gd
    else:
        all_results = gd.get("all_results", [])
    # Any result with score > threshold means it was blocked/steered
    has_cai = item.get("cai_critique") is not None
    if refusal_event:
        return "blocked"
    if has_cai:
        return "critiqued"
    if status_code in (200, None):
        if any(r.get("score", 0) > r.get("threshold", 1.0) for r in all_results):
            return "blocked"
    return "allowed"


def build_ui(api_url: str, api_key: str):  # -> gr.Blocks
    """Build and return a Gradio Blocks dashboard for HITL review.

    Args:
        api_url: Base URL of the harness API (e.g. "http://localhost:8080").
        api_key: Bearer token for the harness API.

    Returns:
        gr.Blocks instance (not yet launched — caller calls .launch()).
    """
    import gradio as gr  # imported here so module loads without gradio installed

    client = httpx.Client(
        base_url=api_url,
        headers={"Authorization": f"Bearer {api_key}"},
        timeout=30.0,
    )

    # -----------------------------------------------------------------------
    # Callback implementations
    # -----------------------------------------------------------------------

    def refresh_queue(rail: str, tenant: str, time_range: str, hide_rev: bool) -> list[list[Any]]:
        """Fetch queue from API and return formatted dataframe rows."""
        try:
            resp = client.get(
                "/admin/hitl/queue",
                params={
                    "rail": rail,
                    "tenant": tenant,
                    "since": time_range,
                    "hide_reviewed": str(hide_rev).lower(),
                },
            )
            resp.raise_for_status()
        except httpx.ConnectError:
            return [[f"Cannot connect to harness API at {api_url}", "", "", "", "", "", "", ""]]
        except Exception as exc:  # noqa: BLE001
            return [[f"Error: {exc}", "", "", "", "", "", "", ""]]

        data = resp.json()
        rows = []
        for item in data.get("queue", []):
            gd = item.get("guardrail_decisions") or {}
            if isinstance(gd, str):
                try:
                    gd = json.loads(gd)
                except (json.JSONDecodeError, TypeError):
                    gd = {}
            triggering_rail = (
                item.get("triggering_rail")
                or _extract_triggering_rail_inline(gd)
                or "—"
            )
            priority = item.get("priority", 0.0)
            action_taken = _action_taken(item)
            correction_action = item.get("correction_action")
            status_badge = correction_action if correction_action else "pending"
            prompt_snippet = (item.get("prompt") or "")[:80]
            rows.append([
                item.get("request_id", ""),
                item.get("timestamp", ""),
                item.get("tenant", ""),
                triggering_rail,
                f"{priority:.2f}",
                action_taken,
                status_badge,
                prompt_snippet,
            ])
        return rows

    def _fetch_item_by_id(request_id: str) -> dict | None:
        """Fetch a single item from the queue by request_id."""
        try:
            resp = client.get(
                "/admin/hitl/queue",
                params={"since": "30d"},
            )
            resp.raise_for_status()
            for item in resp.json().get("queue", []):
                if item.get("request_id") == request_id:
                    return item
        except Exception:  # noqa: BLE001
            pass
        return None

    def select_item(queue_data: gr.SelectData):
        """Handle queue row selection — populate detail panel.

        Gradio 6.x passes SelectData as the sole argument when using .select().
        The selected row index is in queue_data.index.
        The dataframe value is accessed via queue_data.value.
        """
        _empty = ("No item selected.", "", "", "", "")
        try:
            row_idx = queue_data.index[0]
            # queue_data.value is the cell value; we need the row's first column (request_id)
            # Re-fetch via the row index from the stored data
            request_id = str(queue_data.row_value[0]) if hasattr(queue_data, "row_value") else str(queue_data.value)
        except Exception:  # noqa: BLE001
            return _empty

        if not request_id:
            return _empty

        item = _fetch_item_by_id(request_id)
        if item is None:
            return (f"Could not load item: {request_id}", "", "", "", request_id)

        # Build detail header markdown
        ts = item.get("timestamp", "")
        tenant = item.get("tenant", "")
        gd = item.get("guardrail_decisions") or {}
        if isinstance(gd, str):
            try:
                gd = json.loads(gd)
            except (json.JSONDecodeError, TypeError):
                gd = {}
        rail = (
            item.get("triggering_rail")
            or _extract_triggering_rail_inline(gd)
            or "—"
        )
        priority = item.get("priority", 0.0)
        correction_action = item.get("correction_action")
        status = correction_action or "pending"
        header = (
            f"### {request_id}\n"
            f"**Tenant:** {tenant} | **Rail:** {rail} | "
            f"**Priority:** {priority:.2f} | **Status:** {status} | **Time:** {ts}"
        )

        # Parse cai_critique
        cai_critique = item.get("cai_critique")
        if isinstance(cai_critique, str):
            try:
                cai_critique = json.loads(cai_critique)
            except (json.JSONDecodeError, TypeError):
                cai_critique = None

        if cai_critique is not None:
            orig = cai_critique.get("original_output", "")
            revised = cai_critique.get("revised_output", "")
            diff_lines = list(
                difflib.unified_diff(
                    orig.splitlines(),
                    revised.splitlines(),
                    lineterm="",
                    fromfile="original",
                    tofile="revised",
                )
            )
            diff_text = "\n".join(diff_lines)
        else:
            orig = item.get("response") or item.get("prompt") or ""
            diff_text = "(No critique — blocked before revision)"

        return (header, orig, diff_text, request_id, request_id)

    def submit_correction(request_id: str, reviewer: str, action: str, edited_response: str) -> str:
        """POST /admin/hitl/correct with the given action."""
        if not request_id:
            return "No item selected."
        body: dict[str, Any] = {
            "request_id": request_id,
            "reviewer": reviewer or "operator",
            "action": action,
        }
        if action == "edit" and edited_response:
            body["edited_response"] = edited_response
        try:
            resp = client.post("/admin/hitl/correct", json=body)
            resp.raise_for_status()
            result = resp.json()
            return f"OK — {action} submitted for {result.get('request_id', request_id)}"
        except httpx.ConnectError:
            return f"Cannot connect to harness API at {api_url}"
        except httpx.HTTPStatusError as exc:
            return f"HTTP {exc.response.status_code}: {exc.response.text}"
        except Exception as exc:  # noqa: BLE001
            return f"Error: {exc}"

    def approve_click(queue_data, selected_id, reviewer):
        return submit_correction(selected_id, reviewer, "approve", "")

    def reject_click(queue_data, selected_id, reviewer):
        return submit_correction(selected_id, reviewer, "reject", "")

    def toggle_edit_box(current_visibility):
        return gr.update(visible=not current_visibility)

    def submit_edit(queue_data, selected_id, reviewer, edited_response):
        return submit_correction(selected_id, reviewer, "edit", edited_response)

    # -----------------------------------------------------------------------
    # Layout
    # -----------------------------------------------------------------------

    with gr.Blocks(title="HITL Review Dashboard") as demo:
        gr.Markdown("# HITL Review Dashboard")

        # State: currently selected request_id
        selected_id_state = gr.State("")
        edit_box_visible_state = gr.State(False)

        # ------ Top section: filters + full-width queue table ------
        with gr.Row():
            rail_filter = gr.Dropdown(
                choices=["all", "injection", "pii", "toxicity", "content_filter", "jailbreak"],
                value="all",
                label="Rail Type",
                scale=1,
            )
            tenant_filter = gr.Dropdown(
                choices=["all"],
                value="all",
                label="Tenant",
                scale=1,
            )
            time_range = gr.Dropdown(
                choices=["1h", "24h", "7d", "30d"],
                value="24h",
                label="Time Range",
                scale=1,
            )
            hide_reviewed = gr.Checkbox(label="Hide Reviewed", value=False, scale=1)
            refresh_btn = gr.Button("Refresh Queue", variant="secondary", scale=1)

        queue_table = gr.Dataframe(
            headers=["Request ID", "Timestamp", "Tenant", "Rail", "Priority", "Action", "Status", "Prompt"],
            interactive=False,
            wrap=True,
            label="Review Queue",
        )

        # ------ Bottom section: detail + side-by-side panels + corrections ------
        gr.Markdown("---")
        detail_header = gr.Markdown("Select an item from the queue to review.")

        with gr.Row(equal_height=True):
            original_output = gr.Textbox(
                label="Original Output",
                lines=12,
                interactive=False,
                scale=1,
            )
            diff_text = gr.Textbox(
                label="Changes (diff / revised)",
                lines=12,
                interactive=False,
                scale=1,
            )

        with gr.Row():
            reviewer_name = gr.Textbox(
                label="Reviewer",
                value="operator",
                scale=2,
            )
            approve_btn = gr.Button("Approve", variant="primary", scale=1)
            reject_btn = gr.Button("Reject", variant="stop", scale=1)
            edit_btn = gr.Button("Edit", variant="secondary", scale=1)

        edit_box = gr.Textbox(
            label="Edited Response (for Edit action)",
            lines=5,
            visible=False,
        )
        submit_edit_btn = gr.Button("Submit Edit", variant="primary", visible=False)

        status_msg = gr.Textbox(label="Status", interactive=False)

        # -----------------------------------------------------------------------
        # Wire callbacks
        # -----------------------------------------------------------------------

        # Refresh on button click or filter changes
        refresh_inputs = [rail_filter, tenant_filter, time_range, hide_reviewed]
        refresh_btn.click(fn=refresh_queue, inputs=refresh_inputs, outputs=[queue_table])
        rail_filter.change(fn=refresh_queue, inputs=refresh_inputs, outputs=[queue_table])
        tenant_filter.change(fn=refresh_queue, inputs=refresh_inputs, outputs=[queue_table])
        time_range.change(fn=refresh_queue, inputs=refresh_inputs, outputs=[queue_table])
        hide_reviewed.change(fn=refresh_queue, inputs=refresh_inputs, outputs=[queue_table])

        # Row selection in queue table
        # Gradio 6.x: .select() passes SelectData as sole arg (no inputs needed)
        queue_table.select(
            fn=select_item,
            outputs=[
                detail_header,
                original_output,
                diff_text,
                selected_id_state,
                selected_id_state,
            ],
        )

        # Approve / Reject
        approve_btn.click(
            fn=approve_click,
            inputs=[queue_table, selected_id_state, reviewer_name],
            outputs=[status_msg],
        )
        reject_btn.click(
            fn=reject_click,
            inputs=[queue_table, selected_id_state, reviewer_name],
            outputs=[status_msg],
        )

        # Edit toggle
        edit_btn.click(
            fn=toggle_edit_box,
            inputs=[edit_box_visible_state],
            outputs=[edit_box],
        )
        edit_btn.click(
            fn=lambda v: not v,
            inputs=[edit_box_visible_state],
            outputs=[edit_box_visible_state],
        )
        edit_btn.click(
            fn=lambda v: gr.update(visible=not v),
            inputs=[edit_box_visible_state],
            outputs=[submit_edit_btn],
        )

        # Submit edit
        submit_edit_btn.click(
            fn=submit_edit,
            inputs=[queue_table, selected_id_state, reviewer_name, edit_box],
            outputs=[status_msg],
        )

    return demo
