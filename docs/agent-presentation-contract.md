# Temporary agent presentation

`nb.present(key, {view, steps})` explicitly requests a presentation. Reads,
insertions, chat replies and code links do not move the user's view implicitly.
Read `nb.presentation({})` first, then pass its `view`, a stable effect key and a
short step sequence. The presentation ID belongs to the run/key.
`nb.presentation({id})` reads the result; `nb.cancelPresentation(key,{id})`
cancels that presentation. See the [JavaScript API](notebook-javascript-api.md).

A step can set camera center/scale or `focus` bounds, show bounded SVG, or direct
attention. Each step replaces the preceding temporary explanation. A completed
camera move remains where it ended; there is no hidden return camera.

## Ownership and delivery

Mac receives the request through existing IPC. `NotebookPresentationRelay` binds
a single-use view capability to device, iPad launch and the last settled view.
Even a presentation without camera motion consumes it. The relay retains the last
64 receipts and request fingerprints, not SVG bodies. An identical ID/payload
reads its receipt; changed payload conflicts. Losing a receipt does not revive
an old capability.

`NotebookPresentationPlayer` accepts only a current view, an idle surface and a
package no older than five seconds. It never queues behind Pencil or replays after
reconnect. Human contact, navigation, scene change, closure or disconnect interrupts
it. `NotebookInputGate` synchronously preserves accepted Pencil priority.
`SceneCameraSettlement` publishes camera frames through the existing presence
owner. Zooming within an open sheet does not turn it into a cover or select another
item/page.

Presentation uses a bounded transient slot below contact, camera and conversation.
It is absent from content, ink, undo, SharedContext and Codex job storage; only the
final camera follows ordinary local presence persistence.

- `sent`: handed to transport.
- `playing`: execution began; SVG has loaded when present.
- `completed`: the step sequence finished.
- `interrupted`, `rejected`, `unavailable`: a specific reason is retained.

None proves that a person saw or understood the material.

## Coordinates, attention and resources

Bounds use the current board's world coordinates, including open paper.
Screen conversion uses the displayed camera:
`world = center + (screen - viewport/2) / scale`, then tile normalization.
Presentation cannot open another board, document or code file.

One temporary viewport-sized WebKit lease comes from `SceneRenderResources`.
`SceneCameraPlane` applies the material's transform and refines at settlement.
The transparent vector surface does not intercept touches or cover chat controls;
completion, cancellation, rejection and late callbacks release its lease.
JavaScript is disabled and CSP forbids network/external resources. XML validation
rejects external entities, executable tags, embedded HTML, images and handlers.

Limits: 12 steps, 60 seconds total, 48 KiB per SVG, 192 KiB encoded request.
SVG may contain its own vector animation. Persistent programs use ordinary
interactive elements instead.

`steps[].attention` accepts 1–16 current `CollaborationReference` values.
An attention-only step leaves camera and selection unchanged. iPad checks references
in one read transaction; stale source ends with `attention_source_changed`.
Playing waits for all named visible sources and any accompanying SVG readiness.
Offscreen material is not opened automatically. Attention ends with the step,
cancellation, human input or disconnect.

## Feedback for ordinary writes

Ordinary writes do not need `present`. `NotebookAgentFeedback` owns their local
visual lifecycle using addressed results and causal continuation from original
receipts. Initial history loading is silent. New visible results wait for the exact
installed content, then show a 2.4-second accent. Consecutive changes to one item
extend the episode without restarting phase. Offscreen results are consumed without
replay on return; preparation waits at most 30 seconds. Undo or another author's
continuation excludes content no longer attributable to that agent.

Shimmer follows actual glyphs, strokes and contours; Mesh follows fills, new
physical carriers and visible program regions. The overlay shares geometry,
drawing order, erasure masks and accounted installed rasters. On document paper
it borrows the existing PDF raster: letters glow, white paper does not. Programs
retain their native viewports and handlers. Feedback takes no input, is absent
from canonical snapshots/content/undo and uses a static accent under Reduce Motion.

The `presentation` profile covers limits, routing, idempotency, interruption,
Pencil priority and resource release. Installed-device checks must separately
observe appearance/disappearance. Feedback is not a replacement for
`receivedByIPad` / `shownOnIPad` or human visual acceptance.
