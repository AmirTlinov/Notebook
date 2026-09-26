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

A captured `PageInkSource` pins one immutable drawing root and its stamp. Live
publication replaces the owner's root; a delayed lasso cannot read future ink
under its earlier revision. Lazy decoding is shared by readers of that root.

A lifted material edit reserves the ordinary persistence FIFO before asynchronous
preparation. Focus/tool cancellation no longer owns that accepted edit; a later
stroke cannot overtake it. Subsequent picking and lasso read accepted material,
including pending insertions and cuts, while storage checks exact predecessors
and captured ink revisions. Native completion does not wait for its own queued
activity release; foreign contacts and agent admission retain their barriers.

Immutable graphic masks keep polygonal regions and indexed measured absence as
operands of one visibility relation. Live paint, picking and selection controls
do not request a whole Boolean contour. One Metal mask executes captured and
current erasures in their respective frozen bases; local exact queries visit
bounded source chunks and stop at a surviving witness or proven absence.
Controls follow the clipped region, not a fresh bounding box of its holes.
Movement projects this material and publishes changed poses once per surface;
only lift constructs the write payload. Full contours remain explicit export
derivatives, with a separate lock from live region paths. Each derivative has
only a normalized and one body-size slot; decoded equal masks borrow completed
paths without waiting for a build. No raster replaces the authored material.

`PageDocument.prepareInkChange` prepares off-main. Publication rechecks page UUID
and drawing stamp; a concurrent change retries preparation without losing input.
Undo names action UUIDs and does not erase later strokes. Camera waits only for
accepted contact completion; shared edits additionally respect publication fences.

`SpatialInkMesh` keeps tile-local sources. Long, independently renderable ranges
query `InkSampleRelations.Sequence` bounds before preparing display nodes; repeats
have virtual chunks, not one allocated descriptor per logical chunk. Neighbour
halos preserve joins. Display normalization visits only ranges whose projected
neighbours may coincide; distinct branches retain their original bodies. A point
survives when its raw successor is distinct, so returning contours are not
normalized twice. Exact coincident repeat seams retain one trimmed shared body;
a proved stationary range reads only its last measurement. Short prepared strokes
share the existing chunk index instead of retaining one source/index per stroke.

World leaves retain an exact integer tile basis with independent paper and local
world fields. They never flatten large addresses to absolute Doubles. Field
generators must reproduce every IEEE bit; mixed tiles remain literal leaves.
Portable, shared stored bodies and delivery use this same checked graph codec.
Composite receipts can name several bounded ink bodies; the command still pays
for every logical expansion, including cached repeats, within its total read lease.

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

The transient lasso retains one exact, capacity-bounded contour (8,192 admitted
points), not copied per-sample arrays or repeated whole-prefix simplification.
Overflow rejects the contact without replacing the previous selection. Spatial
base, moved-group and live-delta candidate unions reject world bounds before exact
geometry and share one 4,096-object bound; exact work remains off-main.

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
vector source before persistence serialization finishes. The one accepted-page
publication routes both to mounted consumers: a warm inverse visits only the
addressed resident batches, while a cold same-page source keeps its previous
complete material until the replacement baseline and geometry install together.
Lasso preparation does not wait behind JSON/SQLite delivery, and `PageDocument` copies replace their
decoded-cache identity whenever their drawing changes. The cache is a projection
of the archive value, not mutable shared page state.

Cold decoding/index construction still reads the source once. Converting a newly
selected whole stroke still visits that stroke's samples; complete export visits
all visible vectors. Persistence/reload, a dense overlapping scene, and arbitrary
full-source edits do not become constant-time. The existing selection/content
target budgets remain unchanged. Runtime indexes are disposable and never serialized;
images can be replaced without changing selection or saved content.

## Navigation and working sets

iPad navigation has one `idle / interacting / settling` owner. A pinch locks one
hierarchy target at the initial centroid; progress follows the immutable starting
camera between the material's closed/open geometric boundaries. Reversal retraces
that path, release settles to the nearest endpoint, cancellation restores the
initial place. Above the opening boundary paper retains its bounded reading zoom
and pan; horizontal motion while enlarged belongs to camera, not page curl.
Double tap, links and contextual Back use the same prepared settlement mechanism.
A stale preparation cannot accept a replaced intent. A cold target delays acceptance,
not the gesture's camera formula; the outgoing surface remains installed until the
one target cohort is ready. Closed folders do not prepare hidden child scenes.
Board cameras remain free outside the chosen passage. Mac navigation is unchanged.

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
`PageInkProjection` reads the current sheet and exact native demand through the
existing `PageTurnActivity` (all sheets share the notebook's visibility). Demand
promotes the target and synchronously revokes stale readiness before navigation
can capture it. A passive neighbour prepares its first canonical crop but does
not resize its drawable for another
sheet's camera samples. Visible sheets reuse their admitted crop while it covers
the current viewport and satisfies the scene's existing movement-density allowance;
stationary publication refines to current detail. Coverage misses use the existing
512-pixel tile/128-pixel guard policy clamped to the sheet. Promotion refines the
newly visible page. No page-density bucket, second cache or allocation limit is added.

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

### Interactive UX regression gate

`./verify.sh --only --profile interaction-ux` runs on the physical iPad in the
isolated native-test app. It checks the mounted window through the installed
Pencil/finger recognizers: ink and erasure during contact and after lift, a cold
cut of an already erased shape, the next raw-ink cut without confirmation,
tap/whole-object movement, publication and the first following drag. Frozen
window probes require both the new material and the unchanged outside; moving
only a frame or restoring an erased fragment is a failure. Lift checks its first
capture without an eventual-correctness grace period; publication is sampled
through the save/reload boundary, not only in a final still image. Board entry checks
destination pixels; notebook/document opening checks the installed current
source and retains a window screenshot (not an OCR/content-pixel comparison).

Continuous gesture latency has a separate **20 ms maximum for every sample**,
including the first contact. `NotebookInteractionLatencyTests.swift` replays 120
events at fixed 120 Hz deadlines through the same mounted scene and recognizers.
It does not take screenshots, force layout/CA flush, change the display rate or
wait for each event's output. Scheduled time includes backlog; deadlines never
move forward after a stall. Reports retain p50/p95/p99/max, and one late or missing
sample fails even when the percentiles look good. CSV also records `entered_ms`
at handler entry: `handler_ms - entered_ms` isolates handler work from input
backlog without rebasing the acceptance clock. There are two distinct lanes:

- **Input to UIKit update completion:** handler time and the actual
  `UIUpdateLink.afterUpdateComplete` callback, each capped at 20 ms, for pen,
  ink/shape erasure, lasso outline, cold cut movement and whole-object dragging.
  This is necessary app-side responsiveness, **not proof of displayed pixels**.
- **Input to OS Metal presentation:** pen and ink eraser additionally require
  `MTLDrawable.addPresentedHandler` / `presentedTime` within 20 ms. The receipt
  carries the exact encoded contact/revision, and all changed tiles must arrive;
  stale/unrelated frames, zero/dropped timestamps and missing tiles cannot pass.
  Neither GPU completion nor a display-link tick substitutes for this receipt.
  On Simulator, typed GPU completion may advance UI readiness only; the OS
  measurement callback is not invoked, and the physical presentation-timing
  test is explicitly skipped rather than reporting a synthetic pass.
  The observer is optional and nil in the ordinary app path; it never drives
  rendering or changes source/presentation ownership.

The replay measures 120 active-contact samples and the subsequent lift. Metal
receipts cover the active contact; it remains alive while final receipts are
collected (late receipts still fail). Lift has a UIKit budget and separate pixel
continuity checks, not a fabricated Metal receipt for an already retired contact.

Lasso and ordinary selection additionally run
`NotebookSelectionCompositionTests.swift`: the existing **100 ms visual
correctness ceiling**, starting before input and including capture, decoding and comparison.
One image must simultaneously show the expected source cut, moved material,
transported pre-existing eraser hole, unchanged neighbors/ink and selection
handles at the same pose. Old material and retired handles must be absent.
The probes use coordinates frozen before editing, not the current model or
control frames. The contour, cold first cut-and-move, ten movement poses, lift
and tap-away are checked; lift's first image must already be correct. Empty or
off-screen evidence, one missing component, and correct components appearing in
different frames cannot pass. A wholly old pose before the update is different
from a **mixed frame**: new handles with old material, a new body without its
hole/controls, or lost untouched material fails immediately and stays red even
if a later frame is correct within 100 ms. Attachments retain whole-window images,
distinct incomplete compositions, missing components, elapsed time and capture/decode cost.

These sparse window observations deliberately remain separate from the fixed
120 Hz replay: readback must not slow the replay's input schedule or masquerade
as natural gesture performance. The 20 ms input/Metal gates remain unchanged;
passing the visual check does **not** certify 20 ms whole-composition display.
The observer reports `observed-within-20ms` separately and never subtracts
capture cost: window readback itself exceeded 20 ms on the physical iPad.
No production renderer/selection observer or second presentation owner is added.
The window image proves composed output,
not an OS compositor acknowledgement: SwiftUI shape/lasso composition still
does not expose a per-content OS presentation receipt here. Its UIKit lane
alone must not be called a displayed result; system traces and physical
measurement remain required for actual display timing. The Metal lane also
excludes hardware Pencil sensing and physical display scanout.
See Apple's [drawable timing](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime)
and [UI update phases](https://developer.apple.com/documentation/uikit/uiupdateactionphase/afterupdatecomplete).

The separate screenshot correctness ceilings remain **100 ms** for gesture
output, **250 ms** for selection, **1 s** for board/document opening and **2 s**
for cold notebook root startup. These are observation/diagnostic ceilings, not
the latency target. Both the latency gate and the correct-pixel scenarios must
pass; fast model updates alone cannot make a broken interaction green.
Capture and scheduling overhead are included in window checks, not in the
UIKit/Metal replay lanes. Window probes read the current
frame (`afterScreenUpdates: false`), without forcing a synchronous screen update.
The publication monitor yields between snapshots so it cannot starve the writer
while trying to catch up its own sampling schedule. This is not an OS-presented frame
or physical input-to-photon measurement. Hardware Pencil calibration, sustained
system frame/CPU/GPU/memory traces and long-session acceptance remain separate.

The clock begins before input/navigation and is checked after the probe, so a
blocking handler producing a correct result too late still fails. Negative
controls reject wrong/missing output and late synchronous success. Existing
8/15-second opening waits only collect diagnostics; they cannot turn a missed
UX ceiling green. Do not prewarm lasso materialization, insert persistence waits
between ordinary gestures, or raise these ceilings to bless a regression.

### Zoom, page turns and live programs

`./verify.sh --only --optimized --profile navigation-ux` is the physical-iPad
regression route for held-camera visibility, dense pages and 24 independent
JavaScript/CSS programs. The optimized Debug fixture uses ordinary app owners
and an isolated store; it does not alter the installed pair or prefill caches.
Each cold scene has fresh source identities. The first authored pixels must
appear within 150 ms; all pixels and 24 usable runtimes within 1000 ms, both
from the same cold-opening origin before any warm action.
CSS motion is checked in three actual images, including while both zoom contacts
remain held. Each camera handler must finish within 5 ms; queue plus handler
must finish within 16.67 ms from the scheduled input. A coalesced UIKit action
may acknowledge earlier measured revisions of the same contact only when the
latest measured camera pose is actually applied; every covered input keeps its
own original deadline. Equal scales and unmeasured future revisions are not
receipts, and the independent ingestion-queue check remains mandatory. Newly exposed material
requires installed coverage at every observed UIKit commit and correct authored
pixels from the first exposure, with no blank grace period. Missing detail must
refine within 250 ms without making shown material disappear. Coverage observations
do not claim physical presentation or FPS.

Real UI journeys enter through the cover, pinch, swipe in both directions and
rapidly press the folio arrows. They check the requested page's actual pixels,
all 24 first-tap responses, and state after returning. Source availability,
accessibility counters and queued work cannot substitute for these images.
`XCTHitchMetric` records the system hitch ratio for repeated zoom and page-turn
journeys. The selected verifier requires ten samples, each at most 1 ms/s and
33 ms total hitch time; missing, non-finite or over-budget data fails regardless of Xcode's
relative baseline. UIUpdateLink completion is retained as a scheduling diagnostic,
not used as a substitute for this compositor metric. Pencil retains its separate
20-ms input/presentation contract. Navigation requires the first changing
presented frame within 16.67 ms and the complete target within 450 ms of the command.
Changing Metal presentation timestamps must follow the physical display's maximum
refresh rate (0.5 ms timing tolerance); MainActor callback delivery is recorded
separately and cannot stand in for the OS presentation clock.
The image/shadow lane is separate from presentation timing. XCTest/AX transport
watchdogs are not application latency budgets. These are blocking criteria,
not a claim that the current application meets them.

The native turn owner retains at most four stable page hosts. Two bounded sequential
raster executors prepare passive elements, prioritizing the displayed sheet and
requested destination. It does not wait for finger-up or for an offscreen browser
animation frame. Current-page programs keep separate input contexts; only their
passive neighbours share an executor. Raster readiness follows the first real
native layout, not cache acquisition alone. Repeated arrows and released swipes
accumulate the latest requested page instead of queuing obsolete full animations.
Every accepted step contributes to that destination; skipped intermediate pages
are not reported as landings. The same curl is rebased at its current pose to
settle faster during a burst. A contact started during an earlier landing stays
in the existing cold-contact admission path, including reversal and cancellation.
Warm, cold and busy paper share the same lift rule: 44 points of travel or a
forward velocity above 300 points/s, with a reverse velocity below −300 cancelling
the turn. Cold admission measures recent touch motion; readiness does not make a
short flick disappear or turn a reverse cancellation into a committed page.
The window prioritizes the requested page's addressed read before neighbours;
publication still validates its exact source, order and accepted-write boundary.
Unchanged program checkpoints still validate storage but do not reload the scene.
Only an active erasure or its pending handoff mounts a full-page erasure mask;
idle neighbour pages must not allocate transparent work beneath a white mask.
Scene source preparation uses a viewport-relative overscan window, with a larger
durable metadata window behind it. The 96-source, native-owner and runtime quotas
do not grow; offscreen programs are prepared passively, not admitted for input.
Covered minification does not invalidate denser paint during contact. When only
the finite native ink backing needs refilling, the same scene producer prepares
and validates those physical owners at the requested camera, retaining the live
content publication. Unchanged source, workspace, geometry, pins, source crops
and static coverage are still required. New material/exposure/magnification uses
ordinary composition; settlement can reclaim a lower paint LOD.

An already open notebook does not prepare a new hidden cover snapshot. A valid
snapshot from its preceding curl may be reused; changed cover content waits for
an actual closing gesture. While that first snapshot is pending, the cover owner
keeps the last settled endpoint visible (open paper or closed cover), then draws
the current gesture progress. Closed-cover prewarming retains its existing demand
and admission rules. This removes background main-thread capture rather than
merely delaying it until the first page frame. No extra snapshot cache is added.

`IPadSheetCurlController` bends one frozen sheet through the same Core Image /
Metal renderer as covers. It replaces UIKit's fixed binding shadow, not overlays
or private layer mutations. The mounted source/destination keep one parent;
only their stacking changes. A presented endpoint, not elapsed animation time,
confirms the landing. Page progress and drawable submission share one
`CAMetalDisplayLink`; a dropped drawable never confirms a landing. The turn's
image and two drawable backings have one bounded
input reservation, explicitly released at presentation or drained on cancellation.
Snapshot capture runs once outside input dispatch and UIKit update callbacks,
using `drawHierarchy(afterScreenUpdates: true)` on the next main-queue turn.
The queue hop is not evidence of current pixels. Immediately before capture the
page owner verifies the mounted sheet's readiness (source for forward, target for
reverse). Accepted native ink revokes that readiness synchronously, before the
input fence can release; only its current material receipt restores it. A dirty
sheet keeps the same motion, finger progress and lift until its own receipt
resumes capture. The snapshot then requests the current UIKit layer tree. If
that synchronous layout revokes readiness, its image/reservation is discarded
and the same motion waits for the replacement receipt.
A motion ID revokes a cancelled capture; replacing a document source revokes
the motion even when its native hosts are retained. Repeated receipts cannot
replace an already captured image. No timer, idle
observer, extra page cache or replacement button owns this handoff. The snapshot preserves UIKit's native 32/64-bit colour range, avoiding
a full-frame SDR conversion on MainActor. Admission covers an eight-byte source
and the aligned rows of both four-byte drawables; the actual captured row size
is checked before use. It uses
the sheet's actual window-projected density (at most four million pixels), not
the resolution of a larger fitted-offscreen sheet. Live source paper stays in
front until this turn's first resolved curl frame; a preceding drawable cannot
become the new turn's placeholder. The first source-matching frame primes the
unchanged sheet before exposing the other leaf. Source reveal and entry/exit at
the flat boundary install their live underlay in the drawable's transaction.
Command animation starts at that first receipt, not before capture; an interactive
turn retains its measured finger progress instead of restarting it. The Metal view survives turns, its bitmap
backing retires, and progress changes reuse the same immutable Core Image source.
A cold swipe retains its original contact and drives this same interactive curl
as soon as the neighbour is ready; lift/pinch still decide completion/cancellation.
Simulator advances on an explicitly typed GPU completion because it supplies no
drawable presentation callback. That receipt has no display timestamp and cannot
satisfy the physical first-frame, same-event display or FPS checks.
Four alternating native turns check intermediate images, final content, a bounded
left-edge shadow, and return of reserved bytes before the next turn. This route
is regression evidence, not full sustained CPU/GPU/memory or physical-photon
acceptance.

Page projection installs frame, drawable size and layer size atomically before
requesting a frame. The synchronous MTK size callback cannot allocate an
intermediate backing with old/new dimensions. The first empty-page contact also
reports its first drawable's typed completion while the dot remains held; the
regression does not create a screenshot or subsequent move to obtain that receipt.

### Ready-link collaboration and iPad priority

`./verify.sh --only --profile collaboration-ux` checks small edits on an already
ready channel, separately from initial pairing/bootstrap, large attachments and
model inference. Local Pencil retains the independent 20 ms contract above.
For a small ready-link edit, the regression ceilings are **100 ms** to durable
receipt, **200 ms** to correct current window pixels, and **250 ms** for the exact
shown receipt to return. Chat request/reply and iPad context reaching agent IPC
have **100 ms** ceilings. Every sample must pass; report p50/p95/max, not only an
average. These are targets, not a claim that the current implementation meets them.

`NotebookCollaborationLatencyTests` uses two fresh SQLite stores, the app's actual
writer/storage adapter and TLS sessions. Only the iPad's full `NotebookRootView`
is mounted: a source window or Mac rendering cannot be a prerequisite. The root's
ordinary detail-preparation task and display-confirmation path produce the shown
receipt; the test never calls confirmation manually. Ten distinct edits track
action ID, delivery version, content revision, save, completed blob staging,
durable receive, installed page, correct pixels and returned shown. All timings
share the initiator's monotonic clock and include observation overhead. Missing,
stale and late evidence fails; the two-second diagnostic wait cannot grant grace.

The reverse scenario sends ten strokes through the installed native Pencil
recognizer and requires the identical durable ink at the headless peer after lift.
An independent page update must commit while a board contact remains held; that
specific gate starts after verified blob staging, isolating admission from network
delay. Chat control is measured while a bulk durable commit is blocked. Mac tests
read the iPad's exact changing camera/selection through the real agent IPC without
waiting for a preview or altering the Mac's own camera. Existing negative controls
also distinguish stored, received and displayed action/undo phases.

This is **TLS loopback on physical iPad plus a separate real Mac IPC test**, not
a paired Mac/iPad radio or two-screen measurement. Window snapshots are not
photon timestamps; the reverse ink check ends at durable peer content, not Mac
pixels. Discovery, local iPad chat rendering, physical cross-device presentation,
reconnect and concurrent sustained work still need installed-pair acceptance.
Use locally measured stages and a full round trip on one clock; never subtract
unsynchronised device timestamps or substitute saved/received for shown.

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
