---
name: notebook
description: Work together on the user's saved Notebook boards and pages beside a Codex conversation; read selected material, draw, and continue ideas through Notebook tools.
---

# Notebook

Use `notebook_open` when the user wants to open or work together in Notebook.
Pass a known board/page target; otherwise open the admitted current surface. The panel is an
editable view of the user's existing workspace. Conversation and agent execution
belong to Codex.
The panel opens asynchronously while its runtime starts. Read current material
and readiness through `notebook_context`.

Start from the shared material and selected context. Read addressed content with
`notebook_context`; use `notebook_execute` and its `nb` API for agent changes.
Keep related changes in one useful contribution with an exact source basis.
Leave drawings, relationships, labels, and programs editable so the user can
continue them. Use the user's requested style and keep the interface quiet.

The panel saves human gestures through the same Notebook owner and history.
Respect the human's camera, selection, ongoing input, and later contributions.
Panel-only save and undo tools are called by the panel itself.

Tool results describe saved material and delivery. Check a resulting view when
legibility or composition remains uncertain. A reopened panel uses the same saved
workspace. The runtime bundled with the plugin handles persistence and iPad delivery.
