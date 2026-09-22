# Camera and input performance contracts

## Input stays with its admitted owner

`SpatialInkCanvas` checks the actual native receiving view before admitting a new
Pencil contact. Menus/attachments outside chat bounds do not begin ink or lose
their touches to board recognizers. Existing accepted contacts are not canceled
by this new-contact check.

`TwoFingerPaperGestureRecognizer` distinguishes first touch from pair formation.
Undo requires a stationary first finger and at most 150 ms between touches.
Movement ends repeated undo and continues one camera sequence.
Single-pan translation includes movement before UIKit recognition and never
reanchors to a newly arriving second finger.

Passive material yields camera gestures. Mixed web content uses the current
versioned DOM input-region contract in [scene allocation](scene-allocation-contract.md),
rather than an obsolete whole-rectangle assumption. Accepted owner/basis remains
fixed through lift or actual cancellation.

`SceneCameraPlane` installs content basis and camera transform together. Ordinary
camera samples update native matrices without rebuilding items or waiting for
rasters. A basis change completes layout before installing its new matrix.

## Ink, masks and publication

`PageDocument.prepareInkChange` prepares off-main. Publication rechecks page UUID
and drawing stamp; a concurrent change retries preparation without losing input.
Undo names action UUIDs and does not erase later strokes. Camera waits only for
accepted contact completion; shared edits additionally respect publication fences.

`SpatialInkMesh` keeps tile-local sources. Long, independently renderable ranges
query `InkSampleRelations.Sequence` bounds before preparing display nodes; repeats
have virtual chunks, not one allocated descriptor per logical chunk. Neighbour
halos preserve joins. Coalescing-dependent input uses the existing full normalizer;
a proved stationary range reads only its last measurement. Short prepared strokes
share the existing chunk index instead of retaining one source/index per stroke.

Canonical literal blocks borrow one immutable COW sample buffer. Retention counts
its actual capacity once; the joint journal/mesh cache adds only unshared bytes.
Visible CPU geometry and GPU uploads share the existing canvas resource lifetime.
Prepared-node views do not copy their backing arrays. A long finished page contact
retains its pixels while one worker replaces its full incremental mesh with the
queryable source. Later delivery reuses that source. Camera motion changes only
projection; tiles inspect already resident descriptors, not the source again.
The completed live stroke follows the camera before journal preparation.
Metal completion does not synchronously block main; a subsequent installed frame,
not completion of a hidden command alone, permits snapshot evidence.

Dense overlapping eraser triangles are not converted into a pathological main-thread
CoreGraphics softmask. `NotebookElementAppearance` prepares the canonical appearance
off-main; cancellation and SQL-cut validation still precede publication. Ink semantics
are unchanged.

Tile identity separates SQL read cursor from pixel identity. The physical-owner digest
covers ink, undo, off-window elements and child portals, but excludes the board's own
incoming camera. Ready tiles can be reused through the same bounded resource pool
without retaining old cohorts or increasing budgets.

## Interaction work is incremental

`InkElementContact` is the single eraser-contact selector on iPad paper, the
spatial canvas and Mac paper. It freezes the admitted targets once, queries their
bounds for each changed measured segment and retains the first hit per target.
Estimated-input corrections retract only hits from the replaced suffix; the same
selected targets become the accepted action. Full-prefix target scans exist only
as exhaustive test references, not as a second runtime implementation.

Live freehand graphics and pending measured cutouts use `InkMaterialRenderer`
inside the existing `InkCanvasView`. The geometry owner retains visible compact
buffers; camera motion changes their affine, and an appended eraser sample keeps
the unchanged prefix. There is no live `CGImage` readback or full triangle-path
softmask. Explicit exports still use the snapshot renderer. Drawable admission,
MSAA, first-visible-frame readiness and terminal GPU drain have one owner.
Page and scene-cohort receipts aggregate the exact material sources; transferring
a ready host to another cohort replays readiness without redrawing it.

Freehand appearance state and local picking use surviving vector fragments from
that same range geometry, including external captured-basis cuts and the small
label envelope. They do not require a whole-ink CGPath. The displayed frame
clips the query before node preparation, not the source to a unit square.
Whole contours remain explicit export projections; settled live cutouts retain
the native GPU mask instead of switching back to a CPU softmask.

At a fixed camera, active input reuses the unchanged committed-ink query result.
Camera, source and buffer eviction invalidate that result. Mac input no longer
waits for accepted-action delivery before admitting the next contact; the model's
existing ordered write queue owns persistence. Native text extents are bounded
and cached by content, formatting and line width, never by camera/position.

The iPad page renderer also retains the accepted page composite at the current
crop. Pencil frames draw only the mutable contact over that texture; accepting
ink, changing the crop, or replacing the source invalidates it. Empty paper and
per-element material canvases do not allocate this page backing. This is the page
renderer itself, not a screenshot content source or a second persistence path.

Page element erasing has one live page mask driven directly by the admitted
`ActiveEraserStroke`. Movement no longer publishes a growing sample prefix
through `NotebookAppModel` and every element view. Pencil-up transfers the same
measured action and its frozen targets to the accepted write queue; only that
accepted action contributes durable element masks. Both native consumers read
revision boundaries without consuming them, so estimated-tail correction cannot
make the ink canvas or element mask miss a rebuild.

## Compact ink display

Measured source data and persisted actions are unchanged. `InkRenderGeometry` owns
24-byte display nodes (position, contour edge, exact radius, alpha). Stroke RGB is
supplied once per draw; two immutable shared connectivity templates (43,296 bytes
in total) replace per-node neighbours and per-stroke triangle indices. Both apps
use `compactInkVertex`; canonical CPU tessellation remains for semantic picking
and durable freehand triangles, not a second measured-ink display path.

A whole uses a 32-byte affine state. Position and local contour are transformed
in order; an originally circular footprint follows `Q' = A Q Aᵀ`. Joins are the
transformed local contour, not joins recomputed after transformation. This keeps
the existing graphic-transform semantics. No new arbitrary per-node tensor brush
or bit-quantized durable format is introduced. Radius stays Float32 so zoom cannot
magnify logarithmic quantization error. Retained freehand rendering queries its
source hierarchy before preparing the visible vector ranges. Its affine is not
materialized into each point; retained eraser sweeps go directly to compact GPU
nodes rather than expanding all their triangles for every raster job.

Before display-node preparation, the same range query can reject a projected
bound that reaches no sample of the actual Metal raster. `InkRasterGrid` uses
retrieved sample positions, the shader's Float viewport and the actual rounded
pixel dimensions; page crops and integer tile offsets keep that same phase.
Bounds include a pre-cancellation Float arithmetic budget and a 1/16-pixel edge
guard. Unknown sample positions or uncertain bounds do not authorize rejection.
This display predicate never enters vector selection, erasure or persistence.

Empty-coverage rejection is separate from choosing detail for visible ink. The
existing source hierarchy now also retains an opaque-curve certificate: center
deviation, directed tangent envelope and width range. Creation/reload builds it
with the bounded leaves; joins, declared repeats and local edits maintain it with
the same source tree. Tiny primitives neither store this summary nor compute it
for their own display; composition derives it only when an aggregate needs it.
No display pyramid, second index or serialized summary is
introduced. A camera query may stop above the 256-event chunks when this envelope,
projection rounding and both affine stretches satisfy the existing contour budget.
It reads two endpoint events for that decision and at most eight for preparation,
retaining four original nodes, their original cross sections and cap neighbours.
Insufficient detail expands the same query rather than altering the source.

This certificate does not admit translucent ranges, eraser sweeps, reversals or
subpixel-width ink. Opaque coverage still needs raster checks: a contour bound
alone is not a guarantee about the final sampled image. Camera changes hide or
reveal draws via the existing tile owner. A wholly
sample-free overview retains its last nonempty view's already charged buffers
without drawing them; returning to that view does not decode its source again.
A new nonempty selection or geometric exit retires those buffers normally. Tests compare against all original vertices with LOD
and sample rejection excluded from the oracle; device coverage evidence is not
a claim of system frame rate or universal rasterizer precision.

Display-only LOD keeps the original samples. It bounds both contour rails by
0.20 physical pixels and linear alpha error by 1/4096, preserves cap neighbours
and reversals, and restores full nodes on zoom. Affine magnification uses the
largest singular value, including shear. Eraser sweeps and canonical arbitrary
triangles are not simplified. Visibility queries precede GPU uploads; only the
selected level is uploaded. The existing pool may retain its last nonempty
view during a sample-free overview, without allocating hidden source geometry.

The retained spatial canvas compares ordered tile contributors, selected levels,
source revisions and projections. A changed whole invalidates both its former
and current coverage, including a tile whose last contributor disappeared. Only
changed 512-pixel tiles obtain drawables; unchanged tiles retain their presented
layers. There is no second complete retained bitmap. Imported baselines, painter
order, in-flight allocation lifetimes and first-visible-frame readiness remain
part of the same owner. Page MTKView drawing and disposable export raster jobs
are not the spatial retained-tile cache.

An isolated state-update ratio is not a frame-rate claim. Benchmarks must report
GPU and submit/wait separately, preparation and resident payload separately, and
whether LOD or dirty tiles actually removed work.

## Vector source and editing

Native ink remains measured vectors in the immutable journal; selected/copied
freehand retains canonical vector triangles and compact measured cuts. Neither
selection, movement nor undo uses pixels as content. Imported PNGs remain image
assets: this change cannot recover measurements that an imported image never had.
No durable format, transport contract, source sample or existing asset is rewritten.

`InkBoundsIndex` is the one bounds-tree implementation for display chunks and
editing. `NotebookFreehandGeometry` belongs to one immutable source, is prepared
once and shared across affine/style edits. Point picking transforms the query
back into source coordinates; rendering rejects invisible branches before
reading/uploading vertices. Color and painter order survive spatial traversal.
`NotebookGraphic.applying` decodes only the addressed fields; a transform no
longer serializes and decodes all retained source vertices. Validation of the
immutable source is also reused, not repeated at every pose update.

The tool controller retains one prepared accepted lasso snapshot. Its identity
covers the owner, revision and actual spatial-window action membership. Suppressed
stroke IDs belong to the pinned query and do not rebuild unchanged measurements.
Moving the world origin reprojects the query, not the samples. Local
selection indexes whole spans only, then traverses `InkSampleRelations.querySegments`
(the same range owner used by GPU) for candidate measurements and later eraser
ranges. Preparing an accepted relation source does not decode its events or build
a second per-range directory. It keeps original whole-stroke ownership and the existing admission
revision check. Visibility uses vector set differences, not a screen-pixel mask.
Degenerate numerical fragments are rejected at coordinate-ulp precision, not at
a display-pixel threshold; transparent paint does not become selectable content.

Lifted page actions and queued undo are applied to this same decoded accepted
vector source before persistence serialization finishes. Lasso preparation does
not wait behind JSON/SQLite delivery, and `PageDocument` copies replace their
decoded-cache identity whenever their drawing changes. The cache is a projection
of the archive value, not mutable shared page state.

Cold decoding/index construction still reads the source once. Converting a newly
selected whole stroke still visits that stroke's samples; complete export visits
all visible vectors. Persistence/reload, a dense overlapping scene, and arbitrary
full-source edits do not become constant-time. The existing selection/content
budgets remain unchanged. Runtime indexes are disposable and never serialized;
images can be replaced without changing selection or saved content.

## Navigation and working sets

Double-tap explicitly opens paper through one 0.3-second reveal/camera transition.
Back explicitly leaves it. Ordinary zoom neither opens covers nor traverses portals.
An open iPad page remains at least fit-to-page and pans within its edges when enlarged;
horizontal movement while zoomed belongs to camera, with explicit page commands
still available. Board cameras remain free.

Only two stationary single-finger taps on the same document block open its source.
Movement, multiple fingers or cancellation breaks that pair; compatible browser
dblclick does not duplicate touch behavior. Mouse keeps normal double-click.

Native text/vector planes rebase at √2 LOD boundaries; intermediate camera samples
project prepared layers. WebKit identity/canonical bounds stay fixed, while raster
density is independently validated.

`NotebookDiskRefresh` reads in the background through the existing transactional
owner. Camera motion preserves the latest local camera while admitting new content;
accepted Pencil/editing contacts still gate publication. Local edits/navigation
invalidate stale reads. Shutdown drains accepted writes; gestures do not wait on
file locks.

Scene state loads ink only for boards with actual visible/requested windows.
Ancestor metadata does not load all parent ink. Cold notebook opening reads the
selected sheet; `prepareNotebookPage` requests neighbors against the same order.
The four-page `PageTurnPrewarmWindow` distinguishes creation from retention:
unused capacity never creates a distant cold page just to fill the window.

## Attention, history and export work

Numeric JSON ink fields decode as numbers before attempting Boolean decoding.
This retains exact values while avoiding exception work per sample.

History preparation invalidates on actual owner/receipt/context/reference changes,
not equal source values from a newer read sequence. One completed WAL snapshot after
accepted writes supplies receipt, physical version, geometry and continuation.
An unloaded document is not declared deleted.

SQL indexes provide board identities and addressed field continuation without
serializing the entire scene. Whole-created-owner comparison remains complete to
preserve later human adoption. Reference status checks share one read transaction;
known composite IDs are addressed directly, independent of render-job list pages.
A receipt file without its saved request is not evidence. Status reads do not start
new work or change baseline.

Mac export prepares finite ink/raster data off-main and revalidates examined owners
after awaits. PNG encoding runs off-main. Exact publication and live snapshots keep
their own ownership and budgets; see [board publication](board-publication.md) and
[document export](document-export-contract.md).

## How to verify

Start with the affected behavior:

```sh
./verify.sh --plan
Tests/Performance/run.sh
Tests/Performance/run.sh --workspace-copy
```

Choose explicit regressions as needed using
[verification selection](release-build-contract.md#verification-selection).
The performance scripts exercise their documented isolated inputs; they are not
permission to substitute or mutate live app storage.

`InputLatencyTests`, `SpatialInkProjectionTests`, `PageInkPublicationTests` and
`PublicationNoOpTests` cover locks, camera progress, far tiles, buffer reuse, undo
races and no-op publication. Run the affected native gesture and inspect actual pixels.

Historical September 6 measurements, source hashes and negative controls are kept in
[the original report](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/performance.md).
They are not current-device performance claims.

Some UIKit/AppKit snapshots and final composition/crops still run on main.
Off-main preparation still consumes CPU/memory. Display-callback timing in
`runtime/input-frames.json` is written only by an iOS process launched with
`--notebook-profile-input`; ordinary Pencil input does not install its display callback
or rewrite a diagnostic file. That scheduling log and history timing in
`runtime/collaboration-ui.json` do not prove actual presented GPU frames or 120 FPS. Physical gestures, system frame/
CPU/GPU/memory traces, repeated scenarios and long-session acceptance are recorded
separately in [verification](verification.md).
