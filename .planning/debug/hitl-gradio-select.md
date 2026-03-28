---
status: awaiting_human_verify
trigger: "hitl-gradio-select-broken: HITL Gradio dashboard crashes on startup because select_item(evt: gr.SelectData) type hint can't resolve — gr is only imported inside build_ui() but Python's typing.get_type_hints() evaluates in the module's global scope."
created: 2026-03-24T00:00:00Z
updated: 2026-03-24T00:00:00Z
---

## Current Focus

hypothesis: `from __future__ import annotations` at top of ui.py makes all annotations lazy strings. When Gradio calls `typing.get_type_hints(fn)` on `select_item`, it evaluates the string `'gr.SelectData'` in the MODULE's global namespace where `gr` is not defined (only imported inside `build_ui()`). Fix: remove the type hint from `select_item` signature and manually assign `select_item.__annotations__ = {'evt': gr.SelectData}` after importing gr.
test: Run `python -m harness.hitl ui --port 8501 --api-key sk-devteam-test`, verify no crash, verify row selection populates detail panel
expecting: UI starts without NameError; clicking rows shows item details
next_action: Apply fix and validate

## Symptoms

expected: Clicking a row in the HITL review queue should populate the detail panel below with the original output and diff
actual: Either crashes with NameError ('gr' is not defined) when using `evt: gr.SelectData` type hint, or shows "No item selected" / empty panels when using no type hint
errors: NameError: name 'gr' is not defined (at typing.get_type_hints evaluation time), OR "Unexpected argument. Filling with None." warnings flooding the console
reproduction: Run `python -m harness.hitl ui --port 8501 --api-key sk-devteam-test` (with harness running on :5000)
started: Never worked. Multiple fix attempts have failed.

## Eliminated

- hypothesis: The type hint with `evt: gr.SelectData` fails because gr isn't imported at module level
  evidence: Confirmed — `from __future__ import annotations` makes ALL annotations strings; `typing.get_type_hints()` evaluated `'gr.SelectData'` in module globals where gr is absent
  timestamp: 2026-03-24T00:00:00Z

- hypothesis: String annotation `'gr.SelectData'` would work
  evidence: Still fails — string annotations require name resolution in globals, same problem
  timestamp: 2026-03-24T00:00:00Z

## Evidence

- timestamp: 2026-03-24T00:00:00Z
  checked: ui.py line 6 — `from __future__ import annotations` present
  found: This PEP 563 future import makes ALL function annotations into strings at runtime, not evaluated class references
  implication: The annotation `evt: gr.SelectData` becomes the string `'gr.SelectData'` in `__annotations__`

- timestamp: 2026-03-24T00:00:00Z
  checked: Python behavior of `typing.get_type_hints()` on nested functions
  found: `get_type_hints()` evaluates string annotations using `fn.__globals__` (module globals), not the enclosing scope. `gr` is only in `build_ui()`'s local scope, not module globals.
  implication: NameError is unavoidable with the current pattern unless we fix the annotation mechanism

- timestamp: 2026-03-24T00:00:00Z
  checked: Manual `__annotations__` assignment fix
  found: Setting `select_item.__annotations__ = {'evt': gr.SelectData}` assigns the actual class object. `get_type_hints()` sees it's already resolved (not a string) and returns it without name lookup.
  implication: This is the correct minimal fix — no removal of `from __future__ import annotations`, no module-level gradio import

## Resolution

root_cause: `from __future__ import annotations` (PEP 563) makes all annotations lazy strings. `select_item`'s annotation `evt: gr.SelectData` becomes the string `'gr.SelectData'`. When Gradio calls `typing.get_type_hints(select_item)`, it tries to resolve this string in the module's global namespace — where `gr` is undefined (only imported locally inside `build_ui()`). This causes `NameError: name 'gr' is not defined`.
fix: Remove the `evt: gr.SelectData` type hint from the `select_item` signature, and instead manually assign `select_item.__annotations__ = {'evt': gr.SelectData}` immediately after the function definition (while `gr` is in scope). This assigns the actual class object, bypassing string evaluation.
verification: |
  - UI started on :8501 without crash (confirmed by `curl http://localhost:8501/` returning HTML)
  - Harness API at :5000 responded to `/admin/hitl/queue?since=7d`
  - `demo.fns[5]` (select_item): collects_event_data=True, annotations={'evt': <class 'gradio.events.SelectData'>}
  - `typing.get_type_hints(select_item)` returns OK — no NameError
  - Previous NameError is eliminated
files_changed: [harness/hitl/ui.py]
