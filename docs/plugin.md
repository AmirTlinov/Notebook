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
motion requests bounded nearby material through one coalesced render at a time;
the panel keeps one world camera across changes of raster origin. A late response
cannot replace better current coverage, and idle polling does not force another raster.

Plain native text, basic geometry and unbound arrows can be moved, resized,
edited, deleted and undone through human history. Independently editable bodies
receive separate native layers before the gesture starts. Ink and complex
subjects keep their canonical appearance; drawing with Pencil remains available
on iPad. All existing agent tools remain available for the same material.

`MCP/panel` owns disposable camera, selection, draft and gesture presentation.
`Sources/NotebookCore/NotebookPanel.swift` admits each completed human action
against its exact captured native subjects; the installed Mac supplies authorship.
One UUID and immutable request survive response-loss retries. Read polling uses
the native cursor shortcut while unchanged. A panel pins its workspace socket
and target; later model results and old polls cannot redirect a draft or gesture.

`notebook_panel_presentation` joins the existing native addressed-render queue.
Its bounded output contains derived PNG layers and canonical hit geometry.
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
Current delivery and exact check scopes are recorded in
[camera verification](audit-evidence/2026-10-01/codex-camera/results.json) and the
[initial plugin verification](audit-evidence/2026-10-01/codex-plugin/results.json).

This package runs locally on macOS. Public directory submission and remote
hosting are separate distribution work. Plugin manifests follow the
[OpenAI packaging guide](https://developers.openai.com/plugins/build/plugins).
