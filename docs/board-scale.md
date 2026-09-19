# Large-board scaling

## Product contract

A 100,000-item collection should remain navigable through immediate pan/zoom without
requiring 100,000 active WebKit documents. Overview preserves composition; approaching
an area reveals detail and live input. Reduced detail never deletes source content
or changes stable agent addresses.

Camera, paper, page turns and Pencil retain their existing owners. Overview tiles
are derived display, not new editable objects or proof of detailed source inspection.

## Current architecture

`WorkspaceSpatialIndex` contains derived IDs, tiled-world bounds and paint order,
not HTML, document text, program state or ink. Queries bound both visited nodes and
output primitives, including complete-overlap cases where visibility culling alone
would still enumerate the collection.

`WorkspaceSceneIndex` projects the current content owners into that structure.
`NotebookAppModel` prepares generations off-main; camera frames neither rebuild
the index nor hash the catalog. Page navigation has its own derived addressed order,
updated with membership rather than page selection.

`WorkspaceSceneFrame` shares one primitive budget across the board, visible portals
and cover contents. Large covers have local indexes; nesting cannot evade the global
workset bound. Pinned input is preserved first.

`SceneCameraPlane` separates camera transforms from content/workset publication.
Native input and pixels use the same projection. Layers preserve painter order,
ink, lifted objects, stacks and child cameras. Rebase changes the local basis
without changing exact persisted world addresses.

`CompositionTile` maps 512 pixels to a world cell/level using integer tile arithmetic,
including negative and far coordinates. Neighbor endpoints agree without rounding
seams. Coverage planning stabilizes level and coarsens only to fit bounded resources;
an impossible request fails rather than showing an empty board.

`readPaintOrder` yields bounded pages in exact layering order, limiting records and
tree visits. An empty page with a cursor means continuation, not absence.
Cursors bind generation and region. `SceneCompositionRenderer` consumes these pages
sequentially with the same material/ink/portal owners as live display.
Screen publication and exact export share resource ownership but retain distinct
readiness requirements. See [scene allocation](scene-allocation-contract.md).

Addressed SQLite/WAL storage and delivery replace collection-wide JSON rewrites.
The canonical contracts are [spatial replication](spatial-replication-contract.md),
[bounded reads](agent-command-read-allowance.md) and [transport](transport-contract.md).
Historical proposed migration steps are not ordinary update requirements.

## Verification strategy

Use [unique heavy fixtures](load-fixtures.md), not 100,000 references to a few tiny
sources, when validating full mixed-content scale.

| Scenario | Required evidence |
|---|---|
| 1k → 10k → 100k, same visible density | Visited nodes and mounted surfaces do not scale linearly with catalog size |
| Complete overlap | Bounded traversal, meaningful composed pixels and preserved order |
| Large nested cover / portals | One shared workset/resource bound across nesting |
| Input during reads, delivery and capture | Actual gesture continuity and accepted-write preservation |
| Zoom and return | Sufficient installed density, stable identity and resource release |
| Repeated use | No growing queue or sustained memory growth |

The historical full-release target was ≤100 ms warmed response, ≤5 ms p95 main-thread
preparation and no >100 ms stalls on the fixed physical route, followed by ten
repetitions and 30 minutes of collaborative use. These are acceptance targets,
not measured guarantees. System traces must correlate touch, camera version,
GPU and actual presentation; test duration/CADisplayLink is insufficient.

## Historical findings

The September baseline found full-catalog projection/mounting and source loading.
On that Mac, old 100k metadata projection alone took roughly 24–39 ms median;
this measured dependence on collection size, not physical iPad frame time.
Later bounded-index/native-plane profiles established local algorithmic boundaries,
not completion of every large-board gate.

The former roadmap mixed proposed work, then-completed slices and obsolete
migration/installer commands. Its full dated evidence is preserved in
[the original record](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/board-scale.md).
Current open conditions belong to [reliability](reliability-transition.md),
[verification](verification.md) and Linear, not an old roadmap checkbox.
