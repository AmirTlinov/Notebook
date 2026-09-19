# Project files and the vertical code document

`NotebookFileAddress` binds a file to computer UUID, Codex project ID, authorized
root, and relative path. The working copy stays on Mac.
`MacNotebookProjectFiles` performs direct file operations, using current roots from
the Codex connection. Relative paths reject `..`, empty components, and absolute
paths. Descriptor-based traversal rejects symlinks and special files; multiply
hard-linked files cannot be replaced.

One serial file worker owns filesystem operations, independently of SQLite.
Only short intent/result journal steps enter `NotebookPersistenceQueue`.
A request waiting ten seconds reports a timeout while the single worker remains
responsible for the outstanding system call. Retry does not create more blocked
threads. Shutdown cancels pending coordination and prevents new publication.
An already started system call may remain blocked; its durable intent must be
resolved rather than replayed blindly.

## Presentation and refresh

A collapsible tree sits beside the conversation/composer. Each expanded folder
returns at most 64 entries and a continuation. `NotebookCodeDocumentView` opens
above the mounted board and below the chat window. `NotebookFileController`
does not move the paper camera. Closing preserves address, draft, and reading position.
Late callbacks must match the complete file address.

The native text view owns vertical scrolling, selection, search, keyboard, and text
undo. The supported file is UTF-8 up to 2 MiB; unsupported encoding, binary data,
or excess size produces an explicit error without truncation.

The existing visible-chat loop checks eligible folders every three seconds.
A folder refresh is due no earlier than ten seconds after success or fifteen after
failure. Hidden descendants are not polled. A refresh replaces the already loaded
page window and preserves its loaded extent. It performs no file writes and never
retries an unknown save. Computer/project changes fence late replies.

## Drafts, transfer, and saving

`file_drafts` and `file_window` are local state, separate from scene content and
presence. The existing persistence queue orders and coalesces addressed draft/read
position updates. Switching files preserves accepted drafts.

Responses carry at most 48 KiB. Chunks bind one snapshot's SHA-256, length, offsets,
and full file address. Saving stages base and edited content under one ID/hash.
Exact repeats are idempotent; another author or body under that ID is rejected.
Only completed staging creates the durable `chat_job` linked to the draft.
Staging itself does not modify the working file.

Mac merges nonoverlapping line edits. Equal edits count once; overlapping or
ambiguous large rewrites retain both versions. Conflict resolution applies to the
observed Mac version and is rechecked on the next save. Typing during save merges
against the accepted version instead of being replaced by a stale response.

`NSFileCoordinator(.forMerging)` asks cooperating editors to flush. Descriptor,
size, times, and contents are rechecked before atomic replacement; permissions and
metadata are retained. SQLite records intent first and confirmed readback afterward.
After an unknown outcome, Mac compares hashes rather than repeating the write.
Uncoordinated external writers remain outside a global filesystem CAS guarantee.

## Related contracts and checks

See [annotations](code-annotations.md), [discussion](code-discussion.md),
[terminal](project-runs.md), and current [transport](transport-contract.md).
`NotebookProjectFileTests`, `NotebookProjectFilesTests`, and
`NotebookFileControllerTests` cover addressing, real coordinated writes,
conflicts, chunks, draft isolation, recovery, and camera preservation.
The document gesture scenario checks scrolling, keyboard, close, and draft return.
Actual evidence is in [verification](verification.md).
