# Discussing code and annotations

“Discuss selected code” captures the selected paragraphs from the same `UITextView`,
or the visible range when there is no selection. `NotebookCodeFragment` preserves
complete affected paragraphs, original width, and version. It prepares discussion
material; sending remains an explicit action and the chat draft stays editable.

`NotebookAppModel.discussCode` reads accepted ink and intersecting annotations,
up to 32 shared-context fragments. `NotebookCodeImageRenderer` uses the saved
TextKit layout and the existing Metal ink compositor. Its raster belongs to the
reviewed code rather than the current screen position or floating chat.
Existing size, pixel, and memory budgets apply.

`NotebookStore.discussCode` publishes material, `SharedContext`, and immutable
`AgentPinnedSource` values in one transaction. The reference version includes
that code and its ink, excluding unrelated surfaces. A failed raster is recorded
as such; text and measured points remain available without claiming a ready PNG.

Sending uses the existing `attentionContextID`. Mac waits for source delivery
before giving the task to the Codex owner. Later file/board navigation cannot
retarget the pinned context.

## Links and saved answers

`NotebookCodeLink` supports a reviewed fragment, a computer/project file and line,
or the original Mac conversation. WebKit navigation requires an actual link action.
A fragment link locates the old text in the working file; when it no longer matches,
the original annotated material opens instead. An unavailable Mac never causes a
short excerpt to replace its full working file. Board presence and camera are unchanged.

“Save answer to notes” stores the displayed message in the existing shared context
with its source conversation. Known action receipts retain their original material
references. Missing receipts do not attach today's selection to a historical answer.
The note-plus control has a 44×44-point target and an accessible action label.

`NotebookCodeDiscussionTests` covers immutable context, computer identity,
TextKit/Metal pixels, WebKit link activation, saved answers, and camera independence.
End-to-end physical conversation acceptance is recorded separately in
[verification](verification.md).
