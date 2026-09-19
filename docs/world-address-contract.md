# Exact world addresses

`WorldPoint` stores a tile and normalized local offset separately. Persisted tile
indices range from −(2^53−1) through +(2^53−1), exactly representable by Swift
`JSONValue` and JavaScript. Coding rejects values outside that range. Similar field
names inside arbitrary program data are not coordinates and are never rewritten.

`CollaborationInkStroke.worldOrigin` uses the same range. Every measured offset is
validated before creating `SpatialInkAction`. An invalid point rejects the entire
agent batch with `invalid_operation`, including earlier operations, receipt and
cursor. MCP `offsetWorld` enforces the same boundary.

## Camera and native input

`WorldPoint.addressOffset` validates finite offsets, exact integral conversion and
addition overflow before constructing an address. Invalid pan preserves the center;
invalid pinch publishes neither center nor scale. Pinch solves local displacement
before normalization, allowing an out-of-range temporary finger anchor when the
final center is valid. Geometric `offsetBy` is projection, not persisted admission.

`SpatialCamera.worldAddress` separates admitted measurement from `screenToWorld`
geometry. `SpatialInkCanvas` ends a valid span at the address boundary and begins
another when contact returns. Already accepted points survive; no line bridges the
invalid gap. Prediction, pen and eraser share this rule. Entirely external contact
creates no empty UUID and releases input/resources.

`WorkspaceItemPose` validates a drop before publication; refusal restores the
previous cover and allows a later valid drag. Portal entry/exit validates the
destination camera before changing selection or camera.

`interpolatedAddress` interpolates integer tiles and local coordinates separately,
preserving local precision far from zero. Invalid endpoints/fractions fail before
arithmetic. Camera springs and reveal use this owner. Rejected assignment does not
cancel the current trajectory. Creation, movement and stack dissolution validate
addresses before optimistic state, clocks or SQL change.

A stack fan may geometrically extend outside the persisted address range. Rendering
and indexing retain that edge, while cold opening uses its valid board anchor
instead of substituting an invalid page center.

## Derived geometry and bounded queries

`WorkspaceSpatialBounds` encodes derived `origin` and `maximum` using decimal
string `tileX` / `tileY` and normalized numeric `localX` / `localY`.
Canonical strings preserve Int64 across Swift → JSONValue → JavaScript.
Rounded numbers, noncanonical strings, overflow, unnormalized or reversed ends fail.
This does not enlarge the range of persisted physical items.

These geometric bounds also feed read-cursor hashes and paint-order bounds.
MCP/IPC windows use:

```js
{ bounds: { anchor, region: { x, y, width, height } } }
```

`anchor` is an admitted WorldPoint. Offsets are within ±10 million points;
positive dimensions are at most 10 million. The full finite rectangle is validated
before SQL; its external edges are not clipped into physical item addresses.
`visibleBounds` anchors at the exact camera center and works at terminal tiles.
The former `{origin,width,height}` query shape is retired.

## Verification boundaries

Core and MCP tests cover both axes/edges, atomic rejection, far-tile precision,
JSON round trips and cursor invalidation. Native regressions cover measured
recognizer contacts, spans, SQL readback, drops, portals and cold selection.
Simulator pixel comparisons checked identical covers at all four extreme corners
against near-origin controls. These are not hardware Pencil or physical FPS tests.

A historical cold-scene failure exposed a random-UUID fixture assumption:
without saved presence, selection uses the first addressed catalog UUID. The
fixture now explicitly tests both UUID orders rather than retrying randomness.

Exact September 10 source hashes, negative attempts, logs and counts remain in
[the historical evidence](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/world-address-contract.md).
Current release scope is in [verification](verification.md).
