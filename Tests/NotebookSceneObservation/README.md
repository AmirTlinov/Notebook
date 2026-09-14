# Native text ownership observation in Simulator

This is observation-only support for V-R6-01 (`acceptance-native-title` appears
after a pinch). It does not repair rendering or supply acceptance pixels. The
normal Simulator XCTest runner performs all gestures and records its normal
video/screenshots. Only the root runner may run Xcode or Simulator.

After building and installing the new **private** immutable pair through the
existing acceptance route, add `--scene-observation-session <new UUID>` to its
`notebook_acceptance.py ui` invocation. The selected UI test must forward
`NOTEBOOK_SCENE_OBSERVATION_SESSION_ID` to the application. The main
`NotebookAcceptanceUITests.launch` does this. Do not reuse a session UUID.
An independently rebuilt UI bundle cannot add a missing app hook: the driver
checks the selected native source snapshot and installed app identity.

The production app and physical device never enable the journal. The native
observer requires Simulator, a valid private acceptance bundle/manifest, a
nonzero explicit session UUID, and manifest/storage under its actual data home.
It writes `scene-observations/<session>-<launch>.ndjson` beside that private
store. Driver cleanup copies matching journals even after a failed scenario;
`scene-observation-evidence.json` records source and copy hashes. Missing output
is `unobserved`, never PASS. No existing store, journal or evidence is deleted.

Each native camera projection, plane publication/layout, element publication/
layout and retirement is observed at its existing owner. The journal includes:

- `mach_absolute_time`, its timebase and bracketed system uptime, session,
  launch, private run, workspace, source revision, process, executable and
  Simulator identity. `observationBeginMach` to `receiptMach` exposes the
  observer's synchronous cost; this cost must be assessed before trusting a
  timing experiment. `before_commit` events deliberately precede the owner's
  existing Core Animation commit and do not claim display completion.
- Current/anchor cameras and viewport, active/settled phase, current index and
  published generation, preparation flags and viewport coverage. The metadata
  for the plane retains its represented paint ID, separate from the latest
  model publication. Its cohort reference is weak.
- Target membership in the represented workset, requested workset, captured
  frame/index and live owner list, geometry and source version stamp. It never
  logs source text, HTML, program state, clipboard or input text.
- Static tiles in the target's painter range that intersect the viewport and
  target: required raster entry ID versus the existing native installation's
  entry ID and `isInstalled`. Cached pixels alone are not installed coverage.
- The existing `SceneElementPose` host's native identity, bounds/window bounds,
  and a bounded subtree search for real UITextViews. UITextView geometry,
  content size/offset, text-container geometry/insets, edit/focus flags and
  ancestor clipping are read. No extra view is mounted, no focus is requested,
  and no `ensureLayout`, `setNeedsLayout` or `layoutIfNeeded` is added by the
  observer. Existing owner layout calls retain their existing behavior.

The serial utility sink performs JSON encoding and all file writes off the main
thread. Limits: 12,000 records, 16 MiB, 128 pending records. Overload/drop counts
and truncation are explicit; incomplete observations cannot prove a transition
did not occur. Geometry reads and bounded snapshot assembly occur synchronously
on the main actor. These diagnostic builds are not performance baselines.

To distinguish causes, correlate the actual video gap with the ownership log:
an absent workset/live owner or mismatched/uninstalled covering tiles indicates
an admission/installation gap; an unchanged mounted UITextView with nonempty,
correct window geometry throughout the gap narrows investigation to its
rendering. Geometry does **not** prove glyph display, and the latter result is
not by itself proof of a TextKit bug. Video PTS and mach time require an explicit
shared event/clock binding before assigning numerical durations. This journal
does not measure WindowServer display, FPS, hitches or physical iPad behavior.

CPU contracts: `python3 -m unittest discover -s Tests/NotebookSceneObservation`.
Actual pinch/review remains the independent root-controlled native acceptance.

The preserved launch configuration revision is distinct from the installed native
build revision after an upgrade. Preparation records its canonical JSON SHA-256;
collection verifies the actual selected manifest inside the same Simulator
container and compares each journal header with that configuration revision.
The receipt reports the configuration path/hash and native source provenance
separately. A changed manifest or a header carrying the native revision in place
of the configuration revision is rejected; no older-build fallback is used.
