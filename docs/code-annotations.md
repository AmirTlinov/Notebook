# Annotations on reviewed code

`NotebookCodeFragment` preserves computer/project/file address, reviewed-text hash,
UTF-16 offset, excerpt, and original text geometry. It is immutable Notebook material.
`NotebookCodeLocation` is a separately versioned current link; relocating it does
not replace the text or ink surface. `code_fragment_files` is the derived file index.
Reads return at most 64 fragments and continue from the last stored row.

`NotebookCodeInkPresenter` combines the exact `UITextView` layout, `PaperInputView`,
and Metal `InkCanvasView`. Text and ink share local scrolling coordinates.
Backing size follows the viewport, not the entire file. Contact retains its starting
text and width until lift, across editing, file switches, and external updates.

Before releasing `NotebookInputGate`, `NotebookCodeAnnotations` queues the stroke
UUID and measured points. `commitCodeInk` publishes the fragment and
`NotebookSpatialInkCommand` atomically. Failure retains accepted input; closing
finishes contact without cancelling its save. Unmount retires input registration,
preparation, and GPU resources. A mesh prepared for old text cannot appear on new text.

`SurfaceID.codeFragment` uses the existing `SpatialInkJournal`.
The agent reads annotations with `nb.code` and adds real shared ink through
`appendInkStroke`, using content/ink expectations. Human and agent undo retain
UUIDs and points while changing the activity of the owned contribution.
Current delivery compatibility is defined by [transport](transport-contract.md).

## Relocation and rename

On the same file version, ink stays at its original range. After an edit, an annotation
follows only one exact surviving excerpt. Ambiguous or changed text/width preserves
the original annotated material and offers a marker where compatible.
Explicit rebinding can move the link to another range or file while preserving
original text, width, and stroke UUIDs. Different text receives the marker, not
stretched historical handwriting.

`rebindCodeFragment` compares the reviewed location. New strokes do not block
rebinding; a concurrently changed location does. Late ink and old delivery echoes
cannot restore an earlier binding. Editor shutdown closes admission and drains its
read, preventing callbacks from reopening SQLite.

`NotebookFileRename` uses the durable job journal and waits for annotations accepted
before the request. Mac uses `NSFileCoordinator`, validates the project root and
observed file identity, rejects symlinks, and calls `renameatx_np(RENAME_EXCL)`.
An existing destination is preserved. Durable intent precedes rename; identity
readback and new annotation locations establish completion. After interruption,
device/inode/birth-time evidence resolves the result without repeating the rename.

iPad relocates its draft and selection transactionally, preserving an incompatible
draft at the destination. Unknown rename outcome temporarily blocks new code contact;
board and chat remain available. External uncoordinated writers are outside a global
filesystem compare-and-swap guarantee. External renames are not inferred from
similar text; the user can explicitly rebind.

## Verification

`NotebookCodeFragmentTests`, `NotebookCodeStoreTests`,
`NotebookCodeAnnotationsTests`, and MCP/gesture scenarios cover immutable material,
own undo, delivery, reopen, shutdown, real rename, conflicts, and recovery.
See [verification](verification.md) for installed and physical scope.
