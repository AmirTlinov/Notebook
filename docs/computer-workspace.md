# A workspace on a specific Mac

`NotebookChatController` selects one already trusted Mac through `NearbySync`.
A second connection cannot take over that selection. Computer identity is part of
every command even when paths or task IDs match on different machines.

`NotebookStore` keeps active-computer selection separate from each Mac's window.
`chat_panel` and `file_window` use the author/computer pair for conversation, draft,
project, document, file panel, and terminal. `file_drafts` uses the complete file
address. Floating-chat geometry is device-local; the board camera belongs to
`SessionPresence`.

Switching waits for accepted Pencil and queues the old drafts first.
New code contact is briefly fenced while reading the target window. A corrupt or
unread window rejects the switch without discarding the visible draft.
Unknown selection outcome is resolved by reading rather than replacement.
Write failure retains the previous window and text for retry.

`chat_jobs` stores the target computer in the existing journal. Retry cannot change
that target. Terminal input and late voice completion retain their original owners.
Changing a panel does not terminate a process. Late answers, subscriptions, and
prepared editors cannot update another computer.

Migration of earlier single-computer preferences is addressed and transactional.
Messages, IDs, catalog, ink, and camera are preserved; an unbound draft belongs only
to the first selected Mac. Retired unaddressed rows are removed. Historical archives
are not read.

Offline files are labeled as saved copies or local drafts. Reading, editing, and
annotations remain available; refreshing or writing the Mac file requires connection.
Revoking trust preserves Notebook material. A file/conversation link selects its
trusted computer and document, not the board camera.

Native/Core checks cover identical paths on two distinct computer identities,
unknown jobs, persistent drafts, revocation, queue failure, and cold restoration.
A fixture with two peers does not establish physical second-Mac acceptance.
See [enrollment](computer-enrollment.md), [pairing](installation-pairing.md),
and [verification](verification.md).
