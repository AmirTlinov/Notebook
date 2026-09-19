# Camera acceptance from Simulator pixels

This isolated harness records real XCUITest drag/pinch input against an immutable
source snapshot. Baseline and current builds use the same small bootstrap/seed
through NotebookStore. Production scene, camera, WebKit, ink, budgets, and
readiness remain in control. Bootstrap requires a Simulator, the separate
`com.amirtlinov.notebook.cameraaudit` bundle, and a new run UUID. Pairing is
disabled; production containers and archives are untouched.

The fixture has three paper items, two native colored ink strokes, a red SVG,
and a green interactive element. Its static/live variants exercise tile and
native rendering. Historical slot assumptions must be checked against the
selected source revision's resource budget; variant names alone do not prove
which owner actually rendered an item. At 10 and 20 seconds, addressed writes
add/update an independent source with a 4.5-second readiness delay.

Ten pan-out/back and pinch-close/open cycles cross these publications. A tap,
and if needed a double tap, activates a focus-gated historical baseline. AX
button availability is recorded separately and cannot alone establish missing
pixels. This camera scenario is distinct from first-tap acceptance.

## Gesture and source identity

Each cycle includes a continuous 100 × 55 pt pan in both directions at 40 pt/s,
then a fast pair and pinch. The earlier 12 pt/s experiment crossed the 8 pt /
350 ms hold boundary and produced selection holds rather than camera movement;
its recording remains insufficient coverage.

XCTest's requested pinch multiplier does not guarantee the actual synthesized
scale. A historical request of 1.12 produced contact spacing 6.708 → 15.556 pt
(scale 2.319), which the application applied once correctly. The scenario uses
close 0.43 / open 1.12 consistently for baseline/current. Native contact traces
and actual pixel coverage remain necessary.

All native commands share the runner lock; concurrent Xcode runners are rejected.

```sh
python3 Tests/NotebookCameraAcceptance/run.py build --revision BASELINE_COMMIT --simulator SIMULATOR_UUID --evidence .build/camera-baseline
python3 Tests/NotebookCameraAcceptance/run.py build --revision working-tree --simulator SIMULATOR_UUID --evidence .build/camera-current
python3 Tests/NotebookCameraAcceptance/run.py record --build .build/camera-baseline --variant static
python3 Tests/NotebookCameraAcceptance/run.py record --build .build/camera-current --variant static
python3 Tests/NotebookCameraAcceptance/run.py record --build .build/camera-baseline --variant live
python3 Tests/NotebookCameraAcceptance/run.py record --build .build/camera-current --variant live
python3 Tests/NotebookCameraAcceptance/measure.py --video RUN_DIR/simulator.mp4 --output RUN_DIR/measurement
python3 Tests/NotebookCameraAcceptance/run.py record --build .build/camera-current --variant static --lossless
python3 Tests/NotebookCameraAcceptance/measure_lossless.py --run RUN_DIR --output RUN_DIR/lossless-measurement
```

Select a real baseline commit. Historical runs used
`012921b7e8b6ac739c7492071f4ade91e23941e9`.
Measurement requires NumPy, Pillow, macOS AVFoundation/CoreVideo, Swift/Xcode
Command Line Tools, and ffprobe. FFmpeg creates small synthetic CPU-test videos;
the measurement decoder uses native offline decoding.

`build.json` retains revision, hashes before/after test-only insertion,
fixture/bootstrap/UI identity, exact patches, Xcode, and Simulator. An optional
input trace observes UIKit contacts, recognizer cumulative scale, and camera
scale before/after the existing handler. It changes no input or camera behavior
and flushes after gestures. Compare runs with equal `harnessSHA256` and
`inputTraceRecipeSHA256`; patch hashes may differ with source line numbers.
Each exact patch must match its own immutable source.

Evidence includes `recording.json`, `camera-input-trace.json`,
`result.xcresult`, original screenshots, and video.

## Video and lossless measurements

`measure.py` decodes every video frame through the native offline owner and
checks its rational PTS against independent ffprobe inventory. Colored ink
crosses provide observed scale/translation; their physical relationship predicts
SVG/WebKit position. Missing/ambiguous points remain in `frames.csv`.
The historical metric is L∞ with a one-device-pixel threshold, at least 200
measured / 60 moving frames, and no gap exceeding three consecutive frames in
the measured interval. It also requires a passing UI run, all ten settled PNGs,
and the finish PNG. RGB-threshold sensitivity (±16) propagates through both ink
anchors; an upper error bound above one pixel cannot pass.

`--lossless` adds original `simctl io screenshot --type=png` captures to the
same UI scenario, bounded by 1 GiB / 6,000 images. Successful images retain hashes,
dimensions, and start/end capture intervals; failures remain recorded.
A capture observes one unknown instant inside its interval. Request duration is
not continuous observation, and capture frequency is not application FPS.

`measure_lossless.py` verifies every PNG hash. Its primary threshold is
**Euclidean residual ≤1 device pixel**; historical L∞ is supplemental.
Residual (0.9,0.9), for example, is 1.273 pixels. Center uncertainty propagates
through both axes/anchors and yields a residual-length interval.

Complete sampled coverage requires ten cycles, all settled/finish images, at
least 200 measurable PNGs, at least 60 wholly within gestures, and an in-gesture
sample for each contact longer than 120 ms. Fast pans may be shorter than an
external screenshot request; those captures remain measured but cannot claim
wholly contained coverage. Sensitivity checks alone do not certify independent
subpixel/antialias uncertainty.

`completedTenGestureScenario` and `completePixelCoverage` are separate.
A reliable frame with a lower error bound above one pixel is a failure even if
later coverage is incomplete. Acceptance requires both coverage and a passing
measurement. Synthetic `test_measure.py` checks exact projection, a known
four-pixel error, and missing pixels; it does not validate application behavior.

## Joint PNG/video pipeline

`pipeline.py prepare` saves immutable sources, full hashes, tools, Xcode,
Simulator, and sequential phase commands without launching the application.
`run --prepared DIR --phase build|static|live|measure-static|measure-live`
executes only the chosen phase, releasing the native slot between phases.
Each recording has a new UUID; previous failures are retained.

`measure_joint.py` reads every source frame through
`NativeVideoDecoder.swift` / `AVAssetReaderTrackOutput` without resampling.
AVFoundation owns color conversion/chroma placement; Python only reorders
BGRA→RGB and strips row padding. `native_video.py` checks every frame's
dimensions, order, and rational PTS against ffprobe. Missing/extra/reordered
frames, rotation/resize, PTS mismatch, or incomplete decoding are measurement
errors. Original PNG hashes are rechecked. Six RGB/chroma/AA-padding centroid
methods provide independent pixel observations.

Joint contact attribution requires a bounded shared Mach-clock origin and the
entire possible frame-time interval inside the contact, then both ink poses,
actual movement, and direction. Repeated poses across cycles are ambiguous.
No best-fit clock origin, MP4 creation time, or process-start substitution is
allowed. All measurable frames contribute to maximum error, even when
unattributed. Pixel-center coordinates are `(x+.5,y+.5)`.

Coverage retains 200 measurable lossless PNGs, 60 wholly in contacts, all eleven
XCTest checkpoints, and ten cycles. Each contact longer than 120 ms requires
a wholly contained PNG or an unambiguously attributed intermediate video pose.

PNG/video comparison keeps every compatible candidate with matching visible
marker, overlapping time bounds, and both ink poses; it preserves the worst
difference. This bounded visual cohort is not proof of one GPU/display frame:
WebKit can publish independently. Thus `codecCalibrationCertified=false`;
`readyForIndependentPixelReview` alone cannot pass. At least 100 paired PNGs
and 60 motion PNGs are needed. Independent codec calibration requires the same
public CVPixelBuffer for PNG/video, or separately proven pixel invariance.
Resting geometry alone is insufficient.

## Decoder identity and historical findings

Each measurement directory retains copied Swift/Python decoder sources, its own
compiled helper, and `native-decoder/receipt.json`: video hashes before/after,
source/binary hashes, Swift/SDK/OS/architecture, commands, and color metadata.
`ffprobe.json` is independent inventory; `frames.json` retains rational PTS,
dimensions, strides, and native color attachments. Only complete matching output
sets `completed=true`.

A historical H.264/yuv420p frame at PTS 6241/600 in run
`fcaf38dd-004b-4314-b400-fe394cbba037` exposed FFmpeg conversion error:
ink centers differed from PNG by up to 0.66993 px; AVAssetReader reduced that
difference to 0.059923 px. Explicit left-chroma placement fixed only the
horizontal FFmpeg component. This justified replacing the offline decoder,
not moving pixels or relaxing thresholds. Recalculation has a separate identity.

MP4 `nb_frames` may include a trailing discarded packet outside the edit
interval. Run `36474e64-46ad-4c3c-9b0a-f90876f97c77` had 11,011 packets but
11,010 identical decoded-frame PTS entries in AVFoundation and ffprobe.
The last packet was marked discard at 104322/600, the excluded endpoint of
`[0,104322/600)`. Inventory must explain every packet as a decoded frame or an
explicit trailing discard. Internal, unmarked, or unexplained gaps fail.
`test_native_video.py` covers these boundaries, exact PTS, channels/padding,
and actual synthetic H.264 decoding; these are instrument tests.

## Temporal witness

`--temporal-witness` requires a new fixture build and lossless capture.
Only the audit bundle displays a passive 288 × 6 pt marker at y = 84 pt with
run tag, monotonic sequence, and CRC. It takes no input and is hidden from AX.
CADisplayLink requests marker changes; its ticks are not GPU frames or FPS.

Native traces and screenshot bookends use `mach_absolute_ns`. Authentic PNG
markers and neighboring distinct video markers bound the possible PTS origin.
The measurement intersects every constraint, allowing one source PTS quantum.
Empty intersections, regressing sequences, bad run/CRC, or absent witnesses stay
unavailable/inconsistent. Wide intervals may leave short gestures uncovered.
Compatible PNG/video candidates remain in the evidence.

```sh
python3 Tests/NotebookCameraAcceptance/pipeline.py prepare --evidence .build/camera-temporal-provenance-v1 --simulator SIMULATOR_UUID --python /absolute/path/to/python3 --temporal-witness
python3 Tests/NotebookCameraAcceptance/pipeline.py run --prepared .build/camera-temporal-provenance-v1 --phase build
python3 Tests/NotebookCameraAcceptance/pipeline.py run --prepared .build/camera-temporal-provenance-v1 --phase static
python3 Tests/NotebookCameraAcceptance/pipeline.py run --prepared .build/camera-temporal-provenance-v1 --phase measure-static
```

Run `live` and `measure-live` similarly. A new run must establish readable
markers, consistent sufficiently narrow time bounds, complete gesture coverage,
and independent pixel/codec uncertainty. Old runs cannot acquire provenance
retroactively. `test_temporal_provenance.py` checks the protocol, not actual
marker readability in the selected runtime.

This harness measures relative Simulator screen positions. Physical Pencil,
system FPS/CPU/GPU/memory, and long-session acceptance remain separate.
Current results are recorded in [verification](../../docs/verification.md).
