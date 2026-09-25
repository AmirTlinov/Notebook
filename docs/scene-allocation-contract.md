# Scene publication and memory ownership

## Physical owners and coherent publication

Nested boards rest as paper folders, without a book spine or child thumbnails.
A single neutral sheet marks any contained item, element or editable board ink;
the addressed membership read uses the source cut, not the visible camera window.
Native and published covers share the same cached material and tab outline. The
child-board projection exists only for the one admitted entry/return target.
Closed overview folders do not recursively prepare their hidden child scenes.

Board ink reserves backing for the current viewport and full portal in the same
orientation, not a maximum-side square for every possible rotation. Rotation
privately prepares new dimensions and installs atomically; old bounds/pixels remain
until then. All simultaneous CPU/GPU allocations are accounted.

The planner bounds the final workset. Retained outgoing identities are not mistaken
for a second final-owner quota: their real leases remain charged until handoff.
Roles change only for owners of the installing cohort. Existing mounted updates
use their installed cohort and cannot demote an incoming cover between awaits.
An empty identity has no fictitious memory cost or eviction entitlement.

Painter occupancy probes share one SQL read transaction. Nested addressed reads
borrow it and validate the same revision. A transparent offscreen-only board does
not allocate Metal viewport backing merely because distant strokes exist.
Chunk intersection uses the installed camera; source mesh remains available.
Ordinary source and paint pagination share one addressed journal proof: at most 64
intervening delivery-receipt records may advance the journal without changing
material. Another address, unavailable history or an oversized interval rejects
the old source. Workspace identity, bounds, group poses and nested WAL-cut checks
remain mandatory. The source retains only its last proven cursor, never a read
transaction across awaits or a second material revision.

The interactive ink window retains whole admitted contacts, all erasers intersecting
their complete pen extents, and addressed figure masks even outside the camera.
Pins preserve contacts through interaction, not a claim of complete surface history.
The window caps admission at 8,192 actions and 64 MiB of measurement payload; overflow
fails instead of silently clipping the interaction basis. Cold Undo/Redo reads the
existing bounded history directory and exact action headers; reference replacement
changes only retained contributions and preserves unseen ink. Scene preparation
uses one fresh WAL cut on its serial reader after a short FIFO writer fence, not a
heavy writer command. Shutdown joins reads and closes the idle handle permanently.

Mac current-view publication can instead retain the actual renderer's finite pixel
witness: paint-query membership/order, borrowed source/placement records, graphic
claimants, nested portal camera/content and ink-window record hashes. Revalidation
repeats those admitted queries without rendering again or decoding measurement
bodies; an unseen edit cannot invalidate unchanged visible pixels. Page/document
publication checks its addressed content/state/ink headers. The workspace cursor
only discovers possible changes; a still-current witness permits a metadata receipt
refresh without rewriting the PNG. Workspace identity and the final source cut
remain mandatory, with no second render traversal or global dependency cache.
Selection and remembered navigation are receipt metadata, not pixel dependencies:
board/cover keys retain their painted camera/opening; full fitted page/document keys
retain their concrete source and viewport. A queued derived PNG or receipt remains
revocable until its final I/O admission, independently of the shared accepted FIFO.
Input, changed presentation and shutdown revoke only that derived work. The publisher
serializes `runtime.json` on its own off-main I/O task, keeps the heartbeat and joins
in-flight I/O before acknowledging shutdown; late callbacks cannot restart it.

Unmounting/reparenting a document coordinator removes only its own WKWebView from
the prior host, never a newly installed neighbor. Hidden parent boards are prepared
only for the admitted navigation target. A pinch uses the same portal transforms
and readiness boundary as double tap and contextual Back, never a parallel corridor.

`SceneCompositionCohort.geometryID` identifies physical owners, geometry and order;
`paintID` identifies pixel publication. Readiness belongs to the exact
`(plane, elementID)`, source/state, crop and density. A slow program does not block
ready neighbors even in the same painter band. Dependencies rebuild only affected
fragments, preserving other rasters/leases. Affected existing tiles install in one
native transaction. Old pixels may remain as explicit history, not new-version
readiness.

Published objects are not shown evidence. Weak `SceneCameraPlaneInstallation`
validates active window, geometry and completed layout. Static dependencies also
need exact `SceneSourceInstallation` / `RasterLease.entryID`; live sources need the
visible native/WebKit owner. Replacement, hide, unmount or shutdown revokes proof.
An old callback or retained cohort cannot confirm an absent consumer.

First-time and replacement native ink owners use the same private GPU-frame
preparation and atomic installation. There is no hidden-window canvas warm-up
or display-loop polling before a cohort can publish. An unmounted retained
owner keeps its charged backing without remaining in a hidden view hierarchy.
Prepared pixels and OS-presented pixels remain distinct states of that canvas;
layer-transaction completion releases staged resources, not a false visible
acknowledgement. Empty transparent planes need no drawable.

## Raster leases and runtime admission

A remounted consumer first takes exact ready pixels at the required density.
Otherwise it may borrow the preceding cohort's raster for the same physical
address, validated kind, size, provenance and original crop. This neither returns
render-ready nor acknowledges new content. Exact completion refines the same
consumer without another bitmap or executor.

iPad source pixels and precomputed reduction levels share one `RasterEntry`.
Preflight and actual capture charge CPU/GPU copies of all levels.
Camera motion selects an existing level without allocation or implicit animation.
Composition/export read the immutable original. Retaining an older receipt affects
eviction priority, not publication order or which frame is newest.
All levels release after the final lease. Movement permits only bounded √2
upsampling; stationary refinement must meet real pixel density.

`AgentWebSourceFailure` binds source, lease, load token and capture policy.
A changed crop/density cannot inherit an old failure. Program failure revokes input
and live-installation proof; capture-only failure may retain a healthy runtime.
The composition owner retains bounded attempt identities. Explicit Retry creates
a new attempt; resource release does not rerun broken code automatically.

`SceneRasterCaptureRequest` owns the latest crop/density of one source job.
Updates reach that executor directly without cache polling or restarting code.
Load and first capture share one absolute deadline. Event delivery rechecks token,
generation and current request state; queued ready cannot follow a later failure.
Cancel completes readers but submitted backing remains leased until real completion.

A memory retry requires genuinely improved capacity and room for the **whole**
request. The mounted coordinator owns retry; after unmount the composition/page
consumer does, using the same admission predicate. Releasing one's own scratch
does not cause an infinite failure/retry loop.

## Pool and input priority

The shared allocator admits up to 32 visible program owners and two transient
preparation surfaces, with 32 pending requests and two reserved interactive slots.
The board planner keeps its eight native paper/ink owners independent of this
small-program quota; visible controls do not compete for seven paper positions. A live input
program does not consume the passive quota that reserves input for it. Persistent
programs leave preparation capacity. Physical source identity prevents duplicate
execution until the final submitted borrower releases.

Priority follows accepted contact, visible input programs, then visible paper of
the current board, then optional labels/static images. Offscreen portals and labels
do not impersonate input programs. Demoted material returns to its painter range,
preserving content and stacking order. Actual exhaustion yields local bounded
waiting/failure and Retry, never a screenshot pretending to be an interactive button.
Headless requests prepare sources because they have no mounted input owner.

Self-contained full-viewport SVG without browser text/layout uses the existing
bounded SVG-to-PDF kernel and Quartz, publishing through the same raster leases,
crop/density policy and reduction levels. It allocates no WebKit. Admission is
conservative: percentage viewport width/height, no root offset, no text, CSS,
handlers or external resources, and the kernel's existing dimension limits.
Other proven-static SVG retains browser layout preparation; actual programs keep
independent live contexts. One immutable-source classification selects the path;
conversion failure cannot silently switch renderers or substitute fonts.
Passive notebook neighbours share at most two sequential preparation lanes.
Their finite native page window also owns addressed reads: withdrawing a slot
cancels its preparation, and a late response cannot evict a currently needed page.
A re-entering slot gets a new read after the canceled one drains.
The same `NotebookSceneReader` reads a requested page outside the accepted-write
FIFO, after a short writer boundary. A preparation keeps its decoded body only
within that job; reuse checks the existing complete file digest, including causal
fields, not the paint-only reference identity. The final short writer check
validates the order/UUID, file digest, membership witness and exact Undo/Redo
headers. Local admission still revokes an older cut; an unrelated epoch may repeat
these bounded checks but not the unchanged body decode. Publication adds only the
validated page witness to the current catalog, preserving current selection and
other prepared pages. No second page-read tail or long-lived body cache exists.

`capturePresented` freezes the actual installed live surface at Send with source,
state, navigation and visibility guards. `captureCurrent` obtains a later frame
for live/static handoff. Neither restart nor cache may replace historical Send
pixels. `storeAndRetain` returns the new capture, not an older higher-resolution one.

## Allocation failure and density

All native/raster work shares `SceneRenderResources`, including protected active
input capacity. Native cover backing depends on physical page size, not overview
tile count. Native-allocation failure therefore removes an optional native owner
and must strictly reduce their count on the next attempt. Root, pinned and protected
portal owners remain; if none can be removed, fail explicitly.

A failed source capture stays local. New-fragment allocation first lowers overview
density, then removes optional live owners. Mounted visible programs retain their
physical owner while still demanded. Preflight counts real incremental fragments
and scratch alongside old leases, not a hypothetical second full scene.

Coverage alone does not prove sharpness. Settled zoom requests actual screen density
through the same owner. Occupancy first examines at most 256 metadata cells per
plane and reads at most 64 addressed records per cell across bands. The 32-tile
quota applies to occupied cells. Empty areas preserve coverage/order without
consuming raster quota.

`SceneCompositionVectorRun` joins only proven adjacent elements. Unknown/hidden
neighbors retain boundaries. Before allocation, limits remain 32 tiles and
96 primitives; optional vector runs can return to static ranges without disappearing.
Density uses actual pixelSize/worldSize, not a level name.

Large SVG keeps canonical viewport dimensions. Visible crops are pixel-grid rounded,
bounded by 4,096 px per side and 8,388,608 pixels, and retain their original local
origin. Crop/density updates do not restart JavaScript. Open paper requests its
inner scale × fitScale × screen density; overview's 2,048 px policy does not cap
readable full-paper density.

Refinement debt is awakened by contact completion, source readiness or actual
capacity improvement, even with a stationary camera. Accepted Pencil still gates
background geometry publication. Screen partial composition is not written into a
second disk PNG cache; exact export uses sequential painter completion.

## Camera, geometry and contact

Opened paper is temporarily above closed covers and below a finger-lifted item.
`WorkspaceSceneProjection` derives this for both native rendering and attention.
Closing restores order without a content/stack write.

A selected closed cover loads metadata/catalog only. Actual opening loads bodies,
state and drafts. Returning releases paper/WebKit through their owners without
clearing the shared pool or moving the camera.

Pan uses recognizer translation from first contact; a second finger does not reset
single-pan origin. New pan can interrupt spring from the last displayed camera.
Ink's stored camera names installed Metal pixels. New camera samples project those
pixels using the same native matrix as SVG/WebKit; drawable and its basis install
atomically. An accepted contact retains its basis through completion.

Every accepted model presence synchronously reaches `SceneNativeCameraProjection`
and mounted native planes in one bounded transaction. It is not a second logical
camera. Delayed SwiftUI publication uses the latest sample rather than restoring
an older matrix.

Missing coverage may prepare during camera movement; accepted Pencil, editing
contact and remote active input still gate new geometry/publication. The current
geometry job completes toward an admissible result while only the latest next
view is retained. Compatible source jobs survive changing demand and maintain
their original readiness/deadline. Gesture completion separately requests refinement.

`NotebookLiveScenePublication` projects already-admitted addresses from current
logical geometry. Composition owns pixels/workset, not a second current position.
After release, body, frame and hit target immediately use accepted geometry.
Absence from a bounded read is not deletion; explicit deletion or complete addressed
coverage is required. Background work does not steal an accepted contact.

Mixed web content uses versioned DOM input regions through
`AgentWebCoordinator` / `PhysicalWebViewport`, not accessibility frames.
The first owner is fixed by `NotebookInputGate`. Links retain native tap while
allowing pan/pinch cancellation; fields/custom handlers keep their input.
Document-wide handlers own their full region. DOM/listener/size events update the
map without polling. Until a valid matching map exists, WebKit conservatively keeps
input. Coordinates and synthetic clicks are never replayed.

## Detachment and verification

View updates deliver current handlers even when geometry is unchanged; obsolete
manual equality must not retain old captures. Detached thumbnail hosts remove page
demand and raster pins even while UIKit retains their identity; real page handoff
keeps its proper lease. Preflight invokes the same makeRoom eviction owner as actual
allocation but grants no reservation across await.

Tests exercise allocation failure, strict reduction, pixel density, crop identity,
first interaction, stale callbacks and release. Historical diagnostic timing is in
[the original record](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/scene-allocation-contract.md).
It does not establish current CPU/GPU/RSS or physical acceptance:
[verification](verification.md).

A page turn captures UIKit's native color range after its committed layer update;
forcing a whole-sheet SDR conversion on the input actor is not required. The turn
reserves the maximum eight-byte source rows and its bounded four-byte drawable
rows, including alignment, before capture, then checks actual source row storage.
Core Image resolves that same retained source into the existing BGRA8 output.
Retired source completions cannot notify the next turn's readiness/timing owner.
