# Addressed document-block reads

`NotebookStore.readDocumentBlock` returns a `NotebookDocumentBlockRead`: document
UUID, one program, its saved state, and source/state revisions from one WAL
snapshot. It is a partial read, not a complete `DocumentDocument` or
`DocumentStateJournal`.

Before decoding bodies, SQL checks live membership and the lengths of the document
and journal headers plus the selected program/state subtrees. A read admits at
most 4,096 fragments and 4 MiB; an IPC package admits up to four such blocks.
A response-size check after loading is insufficient.

Indexed escaped-address ranges select subtrees. UUID-like IDs are normalized;
ordinary names, Unicode, `/`, `~`, and similar prefixes remain distinct.
Typed structure and parent/collection ownership are validated. A missing block
returns absence; a missing blob behind an existing row reports corruption.

The dispatcher and public SDK's `nb.document({id, blockID})` use this same cut.
Resolving the current document uses presence and its addressed header rather than
loading all current content. Reading leaves camera and human selection unchanged.

A saved JSON `null` differs from an absent state record. Swift and MCP preserve
that distinction instead of replacing accepted `null` with the initial state.

## Checks and scope

Regressions cover admission before decoding, corrupted unrelated bodies among
100,000 states, exact/current-document addressing, escaped IDs, missing blobs,
and unchanged cursors and positions. MCP checks use a real isolated Unix IPC host.

Explicit full-source reads, exports, and the current native document model still
have full-input paths. Addressed block reads do not establish incremental TeX layout,
bounded journal retention, or installed-device acceptance.
See [verification](verification.md).
