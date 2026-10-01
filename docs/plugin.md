# Notebook in Codex

The local plugin opens saved Notebook boards and pages beside a Codex conversation.
Codex owns the conversation and agent. The signed Notebook Mac runtime owns the
existing workspace, ordered writes, script services, and iPad delivery.

The panel displays Notebook's native paper, handwriting, authored content and
physical covers through the existing compositor. Opening follows the admitted
page or board; the panel then owns its camera independently of the iPad. Native
pixel layers keep painter order and refresh together after their source fence
and image decoding complete.

The board background repeats one cell painted by the native grid owner. Camera
motion reuses native world tiles and requests missing coverage through one
coalesced render at a time. The panel keeps one world camera across raster origins;
late responses cannot replace better current coverage. Held immutable assets are
identified by their native raster lease; unchanged polling returns no pixels.
The agent's visible bounds follow the local camera even when no new pixels are
needed; camera context is coalesced after movement.

The projection preserves display pixel density when transport coordinates shrink;
overscan yields to visible pixels. One projection admits 16 Mi pixels within the
existing 32 Mi decoded-material limit. Large covers use visible native regions
at the requested density. The consumer checks actual image dimensions before
reusing a cohort at a new zoom; an identical budget-limited reply does not trigger
an idle redraw loop.

Plain native text, basic geometry and unbound arrows can be moved, resized,
edited, deleted and undone through human history. Independently editable bodies
receive separate native layers before the gesture starts. Ink and complex
subjects keep their canonical appearance; drawing with Pencil remains available
on iPad. Cards move through the existing native placement command, using the
captured placement heads and stack membership. A blank-area drag pans; Escape
cancels a gesture, and double-clicking a card opens its contents. All existing
agent tools remain available for the same material.

`MCP/panel` owns disposable camera, selection, draft and gesture presentation.
`Sources/NotebookCore/NotebookPanel.swift` admits each completed human action
against its exact captured native subjects; the installed Mac supplies authorship.
One UUID and immutable request survive response-loss retries. Read polling uses
the native cursor shortcut while unchanged. A panel pins its workspace socket
and target; later model results and old polls cannot redirect a draft or gesture.

`notebook_panel_presentation` joins the existing native addressed-render scheduler
as an ephemeral reader. Camera requests create no durable render jobs or receipts.
Its bounded output contains missing PNG tiles and canonical hit geometry.
Business subjects are read again at the completed source revision; PNG bytes
remain in the app-only response and never enter model context. The installed
runtime and the iPad keep one saved workspace and the same delivery path.

`MCP/plugin` is the `notebook-local` marketplace; `notebook/` contains the plugin.
Its `.codex-plugin/plugin.json` manifest references `mcp.json`, as supported by
Codex 0.159.3. That file starts the bundled Node and
MCP server from `NOTEBOOK_APP`, `~/Applications/Notebook.app`, or
`/Applications/Notebook.app`. An admitted IPC read precedes startup. If needed,
the app launches with `--background`; readiness waits at most six seconds.

```sh
node MCP/install-plugin.mjs check
node MCP/install-plugin.mjs install
node MCP/install-plugin.mjs uninstall
```

`check` validates source packaging without changing Codex. Installation requires
the updated signed app containing native panel presentation, registers this source with
`codex plugin marketplace add`, and installs `notebook@notebook-local` with
`codex plugin add`. An enabled global `notebook` MCP must first be migrated to
the plugin to keep one tool provider. Existing unrelated configuration is preserved.
Uninstall removes this plugin and its dedicated marketplace; saved Notebook
content and the installed app remain available.

After install, connect the plugin in a Codex conversation and call
`notebook_open`. Verify editing, agent changes, undo, and reopening on that
surface. Native tests and package validation do not establish host rendering.
An existing chat can retain its previous MCP process after installation. If it
reports `Tool notebook_open not found`, `resources/read: Method not found`, or
still displays the old interface after an update,
restart Codex to reconnect that chat, or use a new chat. Reinstalling the same
package does not replace a connection already held by a running chat.
Current delivery and exact check scopes are recorded in
[opening and sharpness verification](audit-evidence/2026-10-01/codex-sharpness/results.json). Previous
[board](audit-evidence/2026-10-01/codex-board/results.json),
[camera](audit-evidence/2026-10-01/codex-camera/results.json) and
[initial plugin](audit-evidence/2026-10-01/codex-plugin/results.json) receipts retain
their original scope.

This package runs locally on macOS. Public directory submission and remote
hosting are separate distribution work. Plugin manifests follow the
[OpenAI packaging guide](https://developers.openai.com/plugins/build/plugins).
