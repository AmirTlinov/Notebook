# Addressed native source commits

`NotebookStore.commitDocumentSource` reads the pinned block, its seven causal
fields, the header, and preamble/order versions in one command transaction.
The complete read is admitted before decoding: 4,096 fragments and 4 MiB.
Draft text retains its separate limit. Neighboring programs, retired-field
history, and the program-state journal are outside this read.

`DocumentDocument.replaceBlockSource` owns the human source version and block
existence acceptance. Publication writes the projection difference.
Native and agent writers share one Store method for admitting new causal fields.
Updating an existing version is addressed; allocating an implicit version may
require an owner-wide SQL count.

Source, terminal draft state, and delivery commit together. A changed basis preserves
conflicting text; removal of a block does not resurrect it. Repeating a completed
session checks the original content and returns the addressed publication without
a second delivery entry.

`DocumentSourceCommitResult` returns a `DocumentBlockSourcePublication`, not an
entire document. The model applies it through `DocumentDocument.mergeSource`,
preserving independent preamble/order changes, newer text/CSS, removal, and the
current human selection. A late result cannot reopen a departed document.

## Checks and limits

Regressions exercise 99,000 unrelated fields, corrupt neighboring bodies, stable
hashes/positions, replay, causal limits, human versions, escaped IDs, pre-decode
admission, and failures before/after commit. Native checks cover application of
late publications and preservation of current UI context.

The full draft catalog and in-memory document model retain separate ownership.
This command contract does not claim a fully addressed editor or incremental layout.
See [source editing](document-page-fragments.md) and [verification](verification.md).
