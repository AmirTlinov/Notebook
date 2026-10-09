# Notebook MCP

Notebook has one native iPad interface. A direct local MCP connection lets the
agent read and edit the same saved content from Codex on Mac.

The signed headless `NotebookRuntime.app` owns the Mac replica, ordered writes,
files, script services and trusted delivery. It starts on demand, retains the
writer after a client disconnects, and has no Notebook window or Dock entry.
The [release owner](release-build-contract.md#build-versus-installation) installs
it and registers `mcp_servers.notebook` through `codex mcp add`.

`NotebookWorkspaceLaunch` admits the catalog identity. `NotebookWorkspaceRuntime`
borrows its single writer, command reader, trusted connection and history owner.
`NotebookHeadlessWorkspace` supplies their Mac lifetime; the iPad model supplies
the accepted native input boundary and presentation. Shutdown joins accepted
preparation and delivery before closing these same owners.

An automatic workspace switch keeps fresh authorship closed while its exact
transition finishes the post-seal read. Only the captured writer seal, unchanged
workspace/input/acceptance basis and current history admission permit continuation.
A stale transition cannot release its successor's seal.

## Tools

- `notebook_workspaces`: list, create, select, rename and retry a workspace through
  the existing catalog owner. It also works before a workspace has been selected.
- `notebook_context`: observe current material, read bounded content, discover
  the SDK, inspect receipts and retrieve exact images.
- `notebook_execute`: run an addressed, resumable JavaScript or TypeScript program
  through the existing isolated native script owner.
- `notebook_import_document`, `notebook_import_document_resource` and
  `notebook_import_program`: admit local files through their existing validators.

Read first, use the returned revision for changes, and reuse the exact action or
run identity after an uncertain result. Resume accepted execution instead of
replaying it. Camera and selection belong to the native iPad surface; presentation
and attention requests use its existing addressed commands.

The runtime preserves content, SQLite, identities, keys and pending deliveries.
`saved`, `receivedByIPad` and `shownOnIPad` are separate outcomes. Local MCP reads
can succeed while the iPad is offline; its last presence is not a current display
receipt. See [collaboration](collaboration.md) and [pairing](installation-pairing.md).

The web panel, its plugin packages, browser renderer and Swift WASM adapter were
removed by Amir's October 8 decision (GUI-541). Their history remains in Git.
