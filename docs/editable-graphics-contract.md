# Editable native graphics

## Content and QuickShape

`NotebookGraphic` is content of the existing AgentElement/SpatialElement.
Page and board persist it through addressed CollaborationAction.
`applyNativeGraphicAction` assigns human authorship; agents cannot choose it.
MCP extends the existing action/transaction API rather than adding an editor.

`NotebookQuickShapeSession` continues an accepted Pencil contact. After a pause it
classifies measured, not predicted, points: ellipse, line, arrow, rectangle/square,
triangle, diamond and plus. Arrow recognition must explain all shaft/wing points
without assuming drawing order. It retains at most three preceding strokes; a
three-second gap, surface/tool/camera change or cancellation breaks the sequence.
Limits are four strokes / 8,192 source points, sampled uniformly by length.
The 500 ms pause, six-screen-point motion threshold and tolerances are calibration,
not proof of accuracy on a user's handwriting.

After recognition, Pencil changes fitted geometry. The held sides follow 1:1 while
opposite sides stay fixed; sides are chosen once and do not jump on reversal.
A 12-screen-point minimum prevents inversion. For connections, the nearest held
endpoint moves, preserving the other endpoint and arrow direction.

The result becomes `NotebookWorkingGraphic` in the ordinary native painter with
the original contact ID, not a second CAShapeLayer/layout graph. Lift submits the
same ID/geometry through the existing queue and retains its draft until the accepted
durable cursor reaches the canonical scene. Late force updates cannot resurrect
raw mesh. Subsequent figures queue normally. Cancellation/forced finish does not
accept conversion. Save/shutdown drains the accepted conversion tail.

## Measured source and causal undo

Graphics reference source stroke UUIDs without duplicating measurements.
Independent causal fields represent visibility and ink/graphic representation.
Removing graphics changes visibility, not measured activity. Converting back to ink
preserves element identity; ordinary ink undo retains its irreversible tombstone.

`NotebookGraphicPresentation` resolves competing complete source sets in stable
order. `graphic_sources` is a rebuildable SQL reference index, including off-window
competitors. Installed ink retains canonical measurements plus a derived display
mask through existing scene publication, not another ink journal.

Field receipts store before/after versions; undo receipts store actual inverse
version → restored-owner pairs. `action_field_restorations` indexes those receipts.
Version addresses follow causal fields (x/y share frame). Equal value after an
independent A→B→A does not restore authorship. A→B→Undo B→Undo A can, including after
reopen/replication. Later geometry/style/label adoption protects the figure until
that change is causally undone. A retained dependent connection similarly protects
its node; undo reports `retained_dependency` with the connection address.

New agent results use the single
[NotebookAgentFeedback lifecycle](agent-presentation-contract.md), replacing the
older standalone 1.8-second graphic highlight description. Human graphics and
initial history loading do not trigger it.

## Picking, contacts and draft publication

Visible contour/fill/label wins over empty interior; otherwise pick the smallest
containing closed shape using its real polygon. Nested content stays reachable and
a huge empty frame does not steal blank-space navigation. Picker, rendering,
attention and erasure share installed geometry.

First native contact refines `NotebookInputGate` ownership before page/camera
recognizers can steal it. Tap selects; movement starts drag. Window lifecycle
releases the contact. A scene finger canceled by Pencil retains identity until lift
but no longer blocks idle indefinitely as a resting palm. Independent native controls
and new finger sequences keep their normal gates.

Second finger or Pencil cancels pending drag without writing; two-finger camera
starts from the installed camera and current finger locations. The remaining finger
does not resume canceled drag. Double-tap opens a multiline native label editor;
Return adds a newline, and completion CAS-checks the original source.

Accepted geometry remains visible until a canonical SQL cut reaches its durable
cursor. A new contact starts from the latest accepted value even while SQL is busy.
Dependent commands compare against their predecessor's exact saved result, not an
arbitrary later read. A failed predecessor cancels dependent edits. CAS failure
removes the optimistic projection and reports conflict without overwriting another
author. Other elements remain interactive.

## Connections and handles

`NotebookGraphicConnection` stores start, end, bend, routing, endpoint styles and
label position as separate causal fields. Free endpoints are frame-local; bindings
hold node ID and normalized anchor, not duplicate node coordinates.
Ordinary binding exits the actual contour; precise binding preserves the anchor.
Picking uses the smallest valid shape, with 14-screen-point acquisition and
21-point retention hysteresis. Only the current target gets a temporary outline.
QuickShape keeps the tip under Pencil instead of snapping it to a contour.

`NotebookGraphicGraph` computes straight, orthogonal or curved routes, Bezier
segments, arrowheads, bounds and hit geometry once for scene, index, render and API.
`graphicResolution` is derived geometry, hidden, or pending with dependency addresses.
`graphic_bindings` is the reverse SQL index. Missing off-window endpoints are read
addressably; unknown remains pending, hidden hides the connection. Projection never
writes repairs to author fields or revives deleted nodes.

Moving a node updates its draft and recomputes dependent lines without coordinate
writes. Moving a bound connection's body detaches its endpoints at their displayed
locations while preserving curvature; frame/endpoints commit atomically and undo
restores bindings. Zero movement/cancel does not detach.

Corner handles affect both axes. Side handles affect one axis and appear only with
112 screen points between corners. Physical handle radius is 12 screen points;
VoiceOver remains 44×44 with adjustable actions. Invisible accessibility corners
do not block paper. Contour tolerance is six screen points. Small-shape centers
remain available for dragging. Shapes can shrink to one local point; paper bounds
still constrain page content. Live resize projects the existing host into accepted
bounds without replacing its runtime.

Polygon controls cycle size/position → vertices → rounding → normal selection.
Vertices remain normalized and convex; moving one cannot cross an adjacent edge.
`cornerRadius` is an independent physical-unit field, bounded by adjacent sides.
One rounded contour serves painter, picking, binding and feedback; geometric queries
flatten its cubics within 0.1 physical point.

A connection's middle handle edits both bend and longitudinal `bendPosition`
(default 0.5). Endpoints/bindings stay fixed. Straight becomes curved when dragged;
orthogonal routing uses the same control point. Route changes preserve endpoints,
label and configured bend.

## Native controls and dense composition

One selection capsule hides during manipulation. Palettes and native menus own their
closing contact. `ElementMenuButton` retains the active UIKit menu throughout its
lifetime; deferred providers update only the next opening. Selection change/unmount
dismisses it. Layer changes read full SQL order, not a partial viewport.

`NotebookChrome` defines opaque light surfaces, quiet borders and one soft shadow:
40-point visible height, 15-point symbols, unchanged 44-point targets.
Chat is opaque and readable above material. This styling owns no input/runtime
behavior and does not change paper, ink or terminal content.

Adjacent author-order graphics share one `SceneCompositionVectorRun` Canvas.
Only an edited label needs a text input. Unknown/hidden neighbors preserve band
boundaries. Native geometry does not consume WebKit slots.
Limits are applied after occupancy probing; an optional run can return to static
painting without losing its content.

When a connection becomes static, dependent movable endpoint runs demote coherently;
a pinned endpoint prevents that demotion. A static node does not force all unrelated
edges to rasterize. Passive figures can select but need admitted live geometry before
dragging. Addressed adjacency and causal proof stay within the 96-item workset.

## Partial erasure

Measured elementTargets remain part of the single ink action.
`InkStrokeGeometry` supplies shared tessellation; `NotebookElementAppearance`
subtracts it from actual contour/fill/heads. Painter, picker and new bindings use
remaining visible content. Fully erased shapes disappear from touch/accessibility;
undo restores them through the same action.

`ink_element_erasures` indexes owner/element action addresses. API appearance is
intact/partial/erased with `sourceIsCompleteAppearance`. Compact observe emits
outOfScope for full erasure and upsert on undo; exact-ID reads still expose historical
source with explicit erased state. Partial source is not complete visual evidence:
render the actual mask. HTML/text envelopes remain conservative, not pixel-exact
browser geometry.

The model's erasure cache keys exact geometry/curves/size/actions. Boolean preparation
runs off-main and serves painter/picker/bindings. Camera/movement does not invalidate
it; pending work cannot publish stale contours.

## Structural clipboard import

`NotebookTldrawImport.prepare` is a pure converter shared by native paste and
`nb.prepareTldraw`. It accepts a selected fragment, yielding separate Notebook
elements, old/new IDs, extent and diagnostics. No tldraw editor/store remains.

Clipboard access occurs only after explicit Paste. Text stays literal editable text;
supported links stay links. Bounded ImageIO decoding orients/reencodes images without
metadata as self-contained existing web content. Structural tldraw markers outrank
preview images/text; corruption fails rather than falling back. Arbitrary clipboard
HTML is not executed. Every format becomes `NotebookPasteFragment` at a captured
`NotebookPasteDestination`; asynchronous selection changes cannot redirect it.

Paste limits: 16 materials, 64 KiB text, 20 MiB per source image / 24 MiB total,
40 megapixels, normalized longest extent 1,600 pixels, 3 MiB finished HTML.
Preparation runs off-main/off-writer; one atomic human action gives one undo.
Saved on Mac does not mean shown on iPad.

Supported tldraw profile:
- Rectangle, triangle, diamond, ellipse; supported rotation/reflection, labels,
  standard light palette and solid fill.
- Two-ended line/arrow, supported internal geo bindings, heads, bend and label
  position. Elbow uses Notebook routing with explicit diagnostics.
- Plain text becomes escaped editable Markdown.
- Groups flatten with world geometry/order preserved; permanent grouping is not
  imported. Handwritten outlines/fonts use Notebook presentation, not pixel parity.
- Unsupported images/assets, draw/custom shapes, complex lines/rich text,
  text/group bindings, other geo, rotated text/non-axis ellipse, URL metadata,
  transparency and hatch fill reject the selected fragment. A selected arrow's
  required node must remain selected. Separate pages are not overlaid.

The bounded decoder accepts the pinned upstream clipboard envelopes v1–v3,
TLContent/schema 2 and single-page .tldr format 1: 1 MiB input, 8 MiB expanded JSON,
512 shapes, 1,024 bindings and bounded nesting/LZ dictionary. Future schemas fail.
It reads no URLs/files and executes no HTML.
Reference upstream: tldraw `e22a70b4985f3b470bbf38af0da22f564758d34b`.

`nb.prepareTldraw({source,selectedIDs,namespace})` takes content, not a path or system
clipboard permission. Read diagnostics/canInsert; a stable namespace preserves
generated IDs. Its empty read basis authorizes no destination write: read the
page/board basis, optionally use `nb.place`, then apply one `nb.transaction`.
Board insertions need exact worldOrigin. See the [SDK](notebook-javascript-api.md).

## Multiple selection

Temporary selection holds at most 32 targets on one physical surface under the
existing selection owner. Context freezes the selected sources, not a pending drag.
One contact applies a common delta; paper clamps the whole construction.
Pencil/second finger cancels all preview without writing.

Move, six alignments, duplicate, delete and layer order are one atomic command/undo.
Full SQL membership preserves selected relative painter order.
Copies receive new IDs and remap internal bindings without acquiring original ink
ownership. Selected connections detach external bindings at displayed endpoints;
unselected connections continue following their nodes.

`applyNativeElementEdits` serves single/multiple edits, checking every shown source
and immutable alignment/copy anchor within one transaction. Any changed source
rejects the batch. Selection publication uses `kind: elements`, physical target and
elementIDs; `nb.observe` reads that exact set, not the first viewport items.
Selection is information, not write authorization.

## Acceptance boundary

Temporary selection does not implement persistent nested groups. Native tests and
synthetic QuickShape contacts do not prove handwriting accuracy, unlimited graph
interaction or physical long-session performance. Current issue states and installed
receipts belong to [verification](verification.md) and Linear.
[Historical implementation and interaction comparisons](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/editable-graphics-contract.md)
retain their original scope.
