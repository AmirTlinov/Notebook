# Page persistence, ink identity and drawing tools

## One persistence path

`NotebookStore.savePage` is the ordinary page-saving API and returns the durable
merged value, not the submitted copy. `PageDocument.merging` prepares the entire
result before assignment. Invalid ink rejects elements/computations in that same
candidate. Native merge preserves the old value and reports failure; store callers
receive an error. Workspace membership and new-page publication share one SQL
transaction, so a failed page also rolls back prepared notebook creation.

`PageInkDrawing` binds each UUID to measured points, tool, color and assigned order.
An exact replay retains that order and cannot revive an undone contact.
Different points under the same UUID or exhausted order fail.
`writeFragment` validates immutable headers and prevents false→true activity revival.
Row position is an order index, not mutable author content.

`InkMeasurements` is the immutable accepted body: a shared relation tree, not a
second representation beside a retained flat array. `NotebookInk/3` and spatial
journal 2 persist its bounded NIM1 graph with exact IEEE fields, repeat exits and
address revisions. Contact freezing, journal metadata changes and mesh bindings
borrow that body. An equivalent replay in another encoding retains the accepted
body/revision; different bits still conflict. Whole placement remains with the
existing graphic/group owner, outside local measurements. Full NIR1 relation
snapshots retain their enclosing exact frames; a placed snapshot cannot silently
be restored as an unplaced journal action.

Explicit command reads export at most 32,768 original samples per ink query,
plus `relations` (the exact NIM1 body). This is a disposable, bounded observation,
not the storage, delivery or rendering path. A compact million-event body can be
saved/read natively without expanding it; requesting every point through this
observational endpoint is refused before materialization. Source directories
remain metadata-only.

Failure publishes no content, receipt or delivery cursor. Imported raster-base
revision is separate and cannot resolve conflicting action UUIDs through last-write-wins.

## Tools and accepted contact

`DrawingTool` / `NotebookDrawingToolSettings` describe intention and local settings,
not content. One nonmodal parameter presenter handles tool settings and color.
First tap selects, repeated tap opens settings. A tap on another real toolbar button
closes settings and selects it in one action. Tapping outside the panel/toolbar only
dismisses; it neither draws nor moves the canvas. Fill is a separate shape setting.

Non-ink Pencil input flows through `NotebookToolInputContact` and
`NotebookDrawingToolController`, fixing physical owner/settings, holding
`NotebookInputGate`, preparing preview and submitting ordinary causal commands.
Cancel or tool change releases it.

Marker is measured ink with constant opacity. Eraser diameter is fixed at contact
rather than pressure-driven, selected logarithmically from 2 pt with numeric values/
presets. One swept-disk geometry without pen miter joints serves live tails, persisted
ink, masks and lasso layers.

Shapes/arrows are `NotebookGraphic`; a line is an arrow setting without endpoints.
Fill and stroke colors are independent. Boolean drawing replaces intersecting closed
operands with one Bezier contour preserving holes, through existing causal undo.
New contact reads accepted logical content and queued drafts, not stale raster cohorts.
Without an operand it creates a normal shape.

Ruler is temporary owner-local pose, moved by finger and rotated at its round end.
Pencil uses the ordinary measurer. `PhysicalPaper` defines 1 cm as two grid cells;
an edge-drawn line becomes normal graphics. Laser writes no content: world points
reproject with camera and decay by per-point time. Its timeline continues after
lift/cancel until the final point expires.

## Lasso and native text

Lasso selects on any intersection, including boundaries. Items/cards select at lift
without waiting for ink preparation. Starting inside a closed card on a board does
not retarget the lasso to its cover. Mixed selection has one
`NotebookSelectionSession` and a 32-target limit; graphics transforms do not pretend
to transform notebook cards.

Ink conversion fixes the accepted tail and prepares a reusable vector bounds
hierarchy off-main. Lasso examines only intersecting sample ranges; visibility is
vector paint minus later cuts, not a bitmap mask. Selected whole strokes use shared
`InkStrokeGeometry` as freehand with source IDs, pressure and ordered pen/eraser
layers. Its immutable source hierarchy serves point picking, subsequent lasso and
visible-range GPU uploads; pose edits share it instead of rewriting vertices.
The existing InkRasterRenderer/Metal path preserves triangle coverage and overlap.
Its replaceable raster is clipped to visibility and at most four megapixels.
Admission rechecks revision; stale selection cannot replace new ink.
Original journal entries remain immutable; a copy gains no authority over their IDs.
Move/scale/rotate use ordinary selection, geometry, erasure and undo.
Preparation limits are 1,024 strokes, 10,000 samples and 65,536 mesh vertices.

Text is created directly by a surface tap, initially sized in screen points then
converted through camera scale. UITextView/TextKit owns caret, selection and line
measurement; the common element queue owns content/undo. Accepted source persists
through editing so scene publication cannot break causal continuation.
Empty completion deletes; late input cannot revive deletion.
Current native text uses fitted geometry consistently for rendering, selection,
hit testing and manipulation, with one clipboard menu. Layer actions share the
ordinary selection UI; exact installed behavior is recorded in verification.

## Erasure semantics

Native geometry is erased by measured paths without raster conversion.
HTML/SVG programs are whole objects: the first actual swept-path intersection sets
`wholeElement` on the action target and unmounts the runtime. Bounding-box overlap
alone is insufficient. Historical actions without the flag retain measured semantics.

`elementTargets` in `PageInkAction` / `SpatialInkSpan` freezes visible target IDs
and local frames at contact start, including exact tiled-world basis for boards.
Points/width live once in that same action, not a second mask journal.

Rendering subtracts measured strips from contour, fill, label and other target
parts. Masks scale/move with the element; new IDs do not inherit them. Prediction
never becomes content. Accepted cuts remain visible through lift until durable ink
publication. Undoing one action restores both its ink and element erasure.

Exact UUID retries must preserve targets. Independent erasures merge without
restoring erased pixels. Scene, export and pinned images use one painter.
Affected passive raster bands cannot carry into a new cohort. Current compatibility
is defined by [transport](transport-contract.md), not the historical version in
which whole-element erasure first appeared.

## Pencil above agent material

Paper composition is paper → material → final ink. A window-level
`PaperPencilGestureRecognizer` receives typed Pencil contacts in installed geometry;
early hitTest does not depend on possibly absent UIEvent touches. Finger reaches
material/scene gestures; accepted Pencil cancels the underlying contact so drawing
over a button cannot also activate it. System panels stay outside paper input.

The same code-ink route accepts only actual text-view descendants, not an overlaid
chat button. Removing/reparenting an owner finishes accepted action; ordinary lift
retains pressure-estimation completion. UUID reservation, persistence and causal undo
remain with the existing canvas/queue.

Object manipulation uses the shown source and one pending selection offset. A tap
selects; actual movement starts the drag. Holding alone does not select or move
material. Pencil cancels the drag preview without writing it. Browser links,
fields, buttons, and authored input regions retain their native input ownership;
no synthetic tap is replayed.

`NotebookPageComposition/2` separates changed painter output from historical
snapshots without rewriting content history.

## Polygon corners and quick shape

Triangle/diamond vertices are 3/4 normalized convex corners, one causal field;
absence means the standard contour. Rendering, picking, snapping and partial
erasure share it. Explicit clear/change and undo preserve authorship.

`NotebookQuickShapeSession` fixes the nearest line/arrow endpoint before first
presentation. That endpoint follows Pencil and snaps to the node point, not a
guessed center/border. Compound recognition hides complete accepted source strokes
without rewriting measured history; shown object/ID survives lift.

## Checks

Core regressions cover duplicate/conflicting UUIDs, order exhaustion, stale pages,
row writes, workspace rollback, replication and replay after undo. Native checks
exercise accepted recognizers, visible erase, selection and publication, with actual
pixel/readback comparisons. Synthetic contacts are not hardware calibration.

[Historical negative controls and profiles](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/page-ink-conflict-contract.md);
[current installed evidence](verification.md).
