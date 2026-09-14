# Ready control latency in iPad Simulator

This diagnostic route observes ordinary product input. It does not intercept a
hit, inject a second click, move focus, replace authored output, or turn a DOM
callback into a presentation receipt. It is not a physical iPad measurement or
an FPS/dropped-frame measurement.

## Owners and endpoints

- `NotebookContactObserver` remains the existing passive window recognizer:
  `cancelsTouchesInView`, `delaysTouchesBegan`, and `delaysTouchesEnded` remain
  false; both prevention methods remain false. Added hooks record begin/end or
  cancellation without changing the winning gesture. Reset abandons an
  incomplete observation; it does not fabricate a touch end.
- `NotebookInteractionDiagnostics` is enabled only in **Simulator**, in the
  validated private acceptance application, with a valid acceptance manifest
  and explicit `NOTEBOOK_INTERACTION_SESSION_ID` UUID. Production and physical
  iPad launches return no recorder and inject no script. Journal ownership is
  separate from persistence, agent state, and scene presentation.
- The native touch record includes the actual `UITouch.timestamp`, a per-touch
  UUID, phase, point, receipt mach ticks, and the actual ancestor WKWebView's
  immutable load token, element ID, readiness, and projected native corners.
  The coordinator binds this identity at load/readiness and retires it with the
  WebKit. Multiple contacts are never guessed from matching coordinates.
- The optional observer script records only trusted pointer/click/input/key
  events. It reads bounded explicitly selected DOM output and records genuine
  mutation observations. Microtask observations are labeled as such; they do
  not mean all event handlers or rendering have finished. Event Timing support,
  its 16 ms requested threshold and 8 ms quantization are explicit; unavailable
  entries are not zero latency. Neither rAF nor CADisplayLink is used as display
  evidence. DOM output is limited to 4096 observations, followed by an explicit
  truncation record; the native journal is limited to 10,000 records/8 MiB.
  All journal file I/O runs on its serial background queue.
- `WindowCapture.swift` captures only the **explicit Simulator window ID and
  Simulator PID**, using `SCContentFilter(desktopIndependentWindow:)`. It first
  checks `CGPreflightScreenCaptureAccess`; false means stop/unmeasured, with no
  permission request. Its console entry point runs on `MainActor` and initializes
  `NSApplication.shared` before shareable-content/filter construction, with OS
  main-thread preconditions. This establishes AppKit's WindowServer connection;
  it does not activate an application, create a window, run the AppKit event loop,
  or change activation policy. The helper never calls input/UI automation APIs. Audio,
  microphone, and cursor are disabled. Each complete delivered screen sample
  receives an original PNG, SHA-256, and its actual
  `SCStreamFrameInfo.displayTime`. Apple SDK describes that field as mach
  absolute time when the frame was displayed by WindowServer. Incomplete/idle
  callbacks retain metadata; suspended callbacks cannot create `started.json`
  or provide an analyzed endpoint. Missing frames are not duplicated or interpolated.

Native touch uptime is calibrated against bracketing native mach ticks. Host
capture records the same timebase and its own bracketing uptime calibration at
start/end. Analysis rejects brackets or disagreement above 1 ms. UI process
identity (actual PID/executable path) must match the native journal; the
Simulator UDID, session, runtime token and PNG hashes must agree.

## Root-runner procedure

Only the root operates Xcode/Simulator. The capture sidecar does **not** start a
second runner. Do not run this route over production data or install a physical
build.

1. Build the current immutable private acceptance slice containing the two new
   native files and `NotebookInteractionAcceptanceUITests.swift`. Use the usual
   preserved-container upgrade; collect the resulting source/build identity.
   The genuine public `acceptance-controls` material must already be delivered
   and mounted through the real paired app.
2. Compile the standalone helper (no Xcode runner):

   ```sh
   DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.5.app/Contents/Developer \
     xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
     Tests/NotebookInteractionAcceptance/WindowCapture.swift -o /absolute/new/WindowCapture
   /absolute/new/WindowCapture inventory
   ```

   Inspect the returned Simulator window/PID/title/frame. A screen-capture
   permission error is terminal for this route. Do not retry through another
   technology or change permission stores. Place the iPad Simulator window at
   useful visible size through the ordinary permitted UI. Inventory alone is
   not frame-capture or latency evidence. The helper rejects a window narrower
   or shorter than 100 points and captures at native point/pixel scale.
3. Select a new absolute control directory **inside the selected private run**
   (do not create it) and a new measurement UUID. The regular acceptance driver
   validates containment and the native source snapshot, then creates it. Pass:

   ```text
   ui --run <private-run> --platform ipad --test <selector-below>
     --interaction-session <measurement UUID>
     --interaction-control-directory <new absolute directory under private-run>
   ```

   The driver sets the **test runner** environment:

   ```text
   NOTEBOOK_ACCEPTANCE_MANIFEST=<current relocated private iPad manifest>
   NOTEBOOK_INTERACTION_SESSION_ID=<measurement UUID>
   NOTEBOOK_INTERACTION_CONTROL_DIRECTORY=<new absolute control directory>
   ```

   Run the usual sole Xcode runner with selector:

   ```text
   NotebookInteractionAcceptanceUITests/testTenReadyControlTapsWithNativeAndDisplayedFrameEvidence
   ```

   The test forwards the private diagnostic environment to the real app and
   reads the actual binary/PID surface. It uses ordinary navigation and waits
   for the ready visible button, then writes `ui-ready.json`. It does not invoke
   a model fixture or start the measured taps before capture acknowledgement.
4. Once the driver creates `configuration.json`, in parallel the root may run this bounded sidecar, with the **observed**
   window/PID. It waits for the UI's real readiness, captures at most 60 seconds,
   and stops on the UI's session-bound end record:

   ```sh
   python3 -B Tests/NotebookInteractionAcceptance/watch_capture.py \
     --control /absolute/control --helper /absolute/new/WindowCapture \
     --session <measurement UUID> --window-id <observed ID> --pid <observed PID>
   ```

   `started.json` is written only after the first actual complete PNG. Ten
   ordinary `button.tap()` gestures must each show count+1 exactly once. The
   screenshots and `ui-ended.json` are behavior evidence, not the latency
   verdict. A sidecar error or missing end leaves the result unmeasured.
5. Collect the native `*.ndjson` for this session from the current private
   manifest root's parent directory, `interaction-diagnostics/`. Files contain
   launch/workspace/source/device identity and do not modify Notebook data.
   The driver also copies only this session’s native journal into its scenario
   evidence and records its hash. On failed UI it cancels only this capture
   session cooperatively; it never kills another process. Preserve the
   unchanged originals alongside capture, xcresult, screenshots,
   helper source/binary hashes, build/source identities, and action sequence.
6. Independently inspect the actual PNGs. For each tap, bind its native contact
   to the single trusted click in the same immutable runtime, and record the
   last captured old count and first captured new count. Inspect the unchanged
   count-only ROI: a pressed-button animation, cursor, moving window or loading
   indicator is not the outcome. This explicit pixel review cannot be replaced
   by a DOM count or a prepared PNG. Example review record:

   ```json
   {
     "sessionID": "<UUID>", "simulatorUDID": "<actual UDID>",
     "reviewer": "<independent reviewer>", "uiEvidence": "<xcresult and screenshot paths>",
     "bindings": [{
       "contactID": "<native touch UUID>", "loadToken": "<immutable WK token>",
       "nativeClickSequence": 20, "selector": "#count",
       "beforeText": "Acceptance count: 0", "afterText": "Acceptance count: 1",
       "reviewedBeforeText": "Acceptance count: 0", "reviewedAfterText": "Acceptance count: 1",
       "lastOldFrame": 10, "firstNewFrame": 11, "countROI": [100, 200, 400, 240]
     }]
   }
   ```

   There must be at least ten distinct complete bindings. Run:

   ```sh
   python3 -B Tests/NotebookInteractionAcceptance/analyze.py \
     --native /absolute/session.ndjson --capture /absolute/control/capture \
     --review /absolute/review.json
   ```

## Reading the result

The explicitly named 100 ms click criterion is **release to actual displayed
outcome**, with separate touch-start-to-display interval/verdict, actual touch
hold duration, and release-to-DOM-receipt value. A release PASS does not claim
that touch-start-to-feedback passed; count output and visible pressed feedback
are separate endpoints. A human or
XCTest holding the button is not attributed to dispatch delay. This definition
must stay explicit when comparing other controls: a slider's relevant endpoint
is its input/value change, not a click after release.

The upper bound is the first reviewed new-state frame's display time minus the
actual native release, including clock uncertainty. The lower bound comes from
the last reviewed old-state frame. Upper bound ≤100 ms passes this criterion;
lower bound >100 ms proves failure; a straddling interval is inconclusive.
Sparse capture may prove a conservative upper bound, but cannot prove a slow
response merely because the next captured frame was late. System dropped-frame
and main-thread measurements remain separate required acceptance gates.

## Static checks and current limit

```sh
python3 -B -m unittest discover -s Tests/NotebookInteractionAcceptance -p 'test_*.py' -v
node --test Tests/NotebookInteractionAcceptance/test_script.mjs
```

These synthetic CPU contracts do not count as Simulator evidence. The initial
2026-09-14 inventory reported the iPad Simulator window as only **70×143 points**,
which remains below this helper's measurement guard. An independent one-second
diagnostic probe later started a stream at that tiny size and received one
`SCFrameStatusSuspended` callback, with zero complete PNGs. A separate metadata
probe established that main-thread AppKit initialization prevents the console
`CGS_REQUIRE_INIT` abort during filter construction. These observations are kept
in `.build/simulator-capture-diagnosis-v1`; they establish neither current frame
availability nor interaction latency. The measurement route still requires a
properly visible real window and an immutable diagnostic build.
