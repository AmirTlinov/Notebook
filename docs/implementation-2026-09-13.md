# Historical audit implementation — September 13–16, 2026

Follow-through for [GUI-199](https://linear.app/main-cluster/issue/GUI-199):
scene/documents GUI-200, Core/MCP/JavaScript GUI-201, isolated acceptance GUI-202.
Starting source: `012921b7e8b6ac739c7492071f4ade91e23941e9`.

This is a historical implementation summary, not the current release checklist.
Use [release procedure](release-build-contract.md) for present verification scope
and [verification](verification.md) for installed status.

## Implemented slices

The first six slices addressed independent material readiness, retained pixels/
runtimes, causal merge and own-action undo, complete contact ownership, then-current
document demand and visible Save. Follow-up defects included low-zoom fine lines,
stale causal identity, thumbnail interception of live handoff and unnecessary
updating chrome during zoom.

The old demanded-prefix DOM paginator was subsequently replaced by the canonical
PDF/SyncTeX engine. Its current contract is [canonical paper](document-page-fragments.md),
which honestly requires whole-document TeX compilation.

## Observed sequence

- Private Release `c4b01e2`: Simulator request→installed/input-ready p95
  504.833 ms cold / 189.856 ms warm on 10/20 large-document transitions.
- v2 `3266642`: cold first-page checks passed, but the first distant link failed
  under memory pressure. A retained cohort and tail-wait ownership were corrected;
  the earlier warm result was not attributed to this build.
- v3 `27824b3`: distant-link failure remained. A memgraph located a stale
  `DocumentWebCoordinator.onSourceChange` capture retaining the old cohort.
- v4 `f1d8286`: distant navigation/return, input, visible Save, kill/cold reopen,
  real Codex editing, stale CAS and own undo passed. p95 was 470.336 ms cold /
  222.013 ms warm. These are Simulator installation-latency measurements, not
  hardware touch-to-photon.
- The broad native run passed 212 Mac / 918 iPad tests, but a final shell assertion
  read a fixture replaced by another scenario. The corrected two-gesture evidence
  did not retroactively rename the old full run PASS.

## Unproven scope

Slice 7 still required physical Pencil/voice, system frames/CPU/GPU/memory,
ten repeats and 30 minutes of collaboration, plus second-Mac connection.
The second Mac's admitted copy and MCP-ready state did not establish pairing.
A Simulator trace localized short keyboard/focus stalls; a separate ready-button
trace had one effect per tap. Neither proved full physical performance.

Complete commands, source hashes, negative attempts and phase tables remain in
[the retained original](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/implementation-2026-09-13.md).
Later installations do not erase those limitations or turn them into current failures.
