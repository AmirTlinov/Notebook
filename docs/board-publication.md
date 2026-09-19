# Board persistence, delivery and display

`NotebookStore` commits actions and the delivery journal. `NotebookDiskRefresh`
admits the current workset and iPad receipt, but that alone is not display.
`NotebookAppModel` requests composition of the exact read state.
If the journal advances across addressed reads, `SceneCompositionSource` rejects
the unshown candidate and `SceneCompositionTiles` requests a coalesced refresh.
The previous complete composition remains until replacement. No camera change,
notebook visit or retry timer is required. Content/memory failures do not become
unbounded retries.

Shown ink requires the installed native source at the same revision and a completed
frame in an active window. Journal/index readiness is insufficient. MCP compares
receipts structurally, so JSON property order is irrelevant; a different ink version
cannot acknowledge an earlier receipt.

## Exact snapshot memory

`SceneRasterCompositor` preserves the native 2× grid and existing budget.
For integer-position, unchanged-density projection, disjoint ink tiles composite
directly into output after independently applying pen/eraser. Eraser affects ink,
not paper or foreign text. Fractional projection retains a unified mask to avoid
filtering seams.

`SpatialBoardGrid` draws in at most 512-pixel pieces into that output, avoiding a
second full-size background bitmap. Covers/shadows and other effect-bearing SwiftUI
views still render whole where clipping would change appearance.

`NotebookSpatialComposition/2` is part of `TargetRenderRequest` identity.
A new renderer cannot reuse an old PNG/error receipt merely because content is
unchanged. Old results/reviewed material remain immutable; current retry and cold
reopen use the same new address.

## Prepared material and selection

Native diagrams project the admitted raster without a second Core Animation cache.
Mounted consumers refine when the existing resource owner publishes sufficient
density. Scheduler and view share `WorkspaceSceneFrame.pixelScales`; zoomed-out
items may need less than one pixel per local point. Canonical SVG dimensions,
overview limits and Pencil reserves remain unchanged. Exact export separately
requests its own density.

`NotebookAgentFeedback` begins Shimmer/Mesh only after exact visible content is
installed. Feedback neither receives input nor moves camera and is not a display
receipt. See [presentation](agent-presentation-contract.md).

`NotebookSelectionGesture` observes the existing native window, without an overlay
that steals board touches. Tap selects; a 350 ms stationary hold can begin region
selection, while earlier movement remains navigation. Selection and manipulation
use [one shared owner](shared-context-contract.md).

## Evidence scope

`BoardPublicationTests` reproduces a journal advance after an agent edit, checks
event-driven refresh, real Pencil-handler erasure, saved UUIDs/readback and rejection
of unshown canvases. Raster checks cover a 2048×2048-point board at 2× inside
160 MiB, fractional seams and deterministic repeated PNGs.

Historical installed build 0.3.32 (35) rendered the formerly failing unchanged
board to 4096×4096 pixels in 1,493 ms, with camera/content unchanged on readback.
That establishes the named reproduction, not every physical erased-ink report or
current performance. GUI-196 remains separately tracked.
[Original evidence](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/board-publication.md);
[current verification](verification.md).
