# Convert retired owner formats outside the application

`BoardDocument` accepts its current format; `DocumentDocument` requires an explicit
paper size. `BoardNode` requires its own `portalCamera` and `portalStamp`.
The live decoder does not reconstruct them from a board or supply A4 for an old
document.

Historical conversion belongs to the separate
`NotebookArchiveTransfer/LegacyDocumentAndBoard.swift`. It renames
`notebookID` / `notebookIDs` in typed placements and stacks, assigns the published
A4 value to an old document and restores an old camera only when its fields are
absent. Corrupt explicit values and unknown formats fail. Same-named fields inside
program source are untouched. Original files remain in their independent copy.

`DocumentDocument.materializingCausalVersions` is the single owner for making
implicit initial clocks explicit. SQL publication and external preparation both
call it without adding an edit or incrementing clocks. Prepared checkpoint and
readback must match exactly. Transfer reports identify each converted owner using
the source-file SHA-256 and prepared logical-owner SHA-256.

## Historical verification

The September 10 immutable development profile passed 62 Core tests and
26 external-transfer tests, covering identities, stack order, coordinates, clocks,
program source/state, source-file preservation, strict decoder refusal and
activation recovery. The first compile failure and subsequent implicit-clock
readback failure were retained before the final pass. This was a focused
implementation check, not installation or physical acceptance.

[Original detailed evidence](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/retired-owner-conversion.md).
Current execution rules: [archive transfer](archive-transfer.md).
