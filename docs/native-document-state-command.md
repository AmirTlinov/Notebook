# Native state: one accepted program

`NotebookAppModel.commitDocumentState` accepts a value into the displayed
`DocumentStateJournal`, then queues a `NotebookDocumentStateCommand` containing
the document UUID, one block record, and its accepted clocks. The closure retains
that command rather than the entire journal.

`NotebookPersistenceQueue` preserves A, B, A ordering even while the first write
is blocked. Shared-attention capture forms a fence between earlier and later values.
A failed write retains the accepted block and dependencies for explicit retry.
Navigation does not redirect it. Shutdown drains accepted commands; callbacks after
final model termination cannot create new writes.

## Storage and causality

`NotebookStore.commitDocumentState` reads live document membership, the journal
header, and one block subtree. It leaves unrelated sources, states, and positions
untouched. Retired program states remain history; removing the document prevents
a delayed command from recreating its journal.

`DocumentStateRecord.replace` uses the same direction as delivery. The command
keeps the causal version accepted at input; it cannot claim a newly observed
stored version as human continuation. The aggregate advances once for a new
combined visible state. A losing stale value or exact retry creates no new frame.
Counter exhaustion rejects publication.

A native command requires an explicit accepted causal version. Validation includes
the record stamp, causal-version validity, and the existing bound of 256 observed
authors. Both local and incoming merges obey it. Existing implicit versions remain
part of the historical domain format, not a fresh native contact.

`publishProjectionEdits` writes the selected block difference, including removed
nested JSON collections. `writeFragment` owns the physical write. State, clocks,
and delivery share one SQLite transaction; the response returns the accepted
block and final clocks. Exact retry resolves an ambiguous post-commit response.

## Verification

Core checks cover 100,000 unrelated records, corrupt unread bodies, nested collections,
similar IDs, causal union limits, counter exhaustion, human continuation, and faults
around commit. Native checks cover queue order, observation fences, retry, navigation,
and terminal shutdown. See [verification](verification.md) for evidence scope.
