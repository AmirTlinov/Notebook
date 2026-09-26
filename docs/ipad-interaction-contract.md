# iPad interaction owners

The top-right toolbar and circular chat button are window chrome; neither changes
the canvas geometry. The iPad presents the existing Notebook model; Mac presentation and content/wire
formats are unchanged. Tool styles remain independent device preferences.

- `NotebookAppModel.drawingTool` owns the primary tool. Drawing groups pen and
  marker; Shapes groups figures and real bound connectors. Selecting an inactive
  group restores its last tool; repeating opens choices and settings. Pointer has
  its own toolbar button: one tap selects it, repeating opens its trail setting.
  Its color uses the same primary palette; it is never a pen subtype or a second
  selection owner. The code-document ink-only toolbar excludes non-ink tools.
- `NotebookDrawingToolController` owns the single transient physical guide.
  Geometry tap toggles the last kind, hold/accessibility action opens settings.
  Ruler, protractor and compass never replace the primary tool or enter Undo.
  The current surface retains its disabled pose; leaving it releases that pose.
- `GuideConstraintSnapshot` freezes surface and geometry at contact admission.
  Only a start within 12 screen points acquires a constraint. Measured, predicted
  and estimated points use the same affine projection; force, opacity, timestamps,
  persistence, erasure and native history retain their normal owners. Guided
  contacts exclude QuickShape. Pose changes wait for accepted Pencil completion.
  Material units do not change with camera scale; angle display is 0.1 degrees.
- `NotebookSelectionGesture` resolves and freezes callbacks on finger-down.
  Quiet hold-up opens actions; hold then motion moves the original material.
  Another finger or Pencil cancels that ownership. There is no competing hold
  recognizer or zero-motion edit. Selection frames and grips remain visible;
  whole-object actions live only in the contextual menu. Native inline text
  selection retains its system editing controls.
- `NotebookContextMenus` owns menu/popover presentation. Existing model operations
  revalidate captured selection identity and their addressed source when invoked.
  Menu eligibility reads bounded selection metadata without serializing bodies.
  Explicit Copy captures typed material once and encodes the fragment off the UI
  actor. Copy publishes that immutable snapshot even if selection changes; a newer
  copy command cancels the old one. Cut rechecks selection, source/ancestor poses
  and ink revision, and deletes only after that check and the clipboard write. Clipboard paste
  reidentifies it through the existing atomic element/history writer. Text also exports plain text for
  other applications. An unavailable target fails, never redirects to a new one.
- Confirmed blank single taps toggle chrome without resizing/remounting content.
  Open tool/context panels consume their dismissal contact first. Selection,
  text input, Pencil and a second tap are not blank-toggle commands. Hidden chrome
  has neither accessibility nor touch regions; failures/decisions remain visible.
  An explicitly expanded chat stays visible and interactive independently of this
  chrome toggle; only its own collapse control hides the conversation.
- One compact chat button reflects the existing dictation/voice owner. Modes,
  mute and stop live in full chat. Collapsing does not stop capture. The microphone
  worklet reports measured RMS at at most 10 Hz using the existing capture;
  silence/mute/end reset the neutral glyph. No synthetic speech animation or
  second microphone stream is created.

Navigation uses one `idle / interacting / settling` state in `SpatialWorkspaceView`.
`NotebookZoomPassage` interprets immutable `CameraGestureTrajectory` samples,
locking one initial-centroid target and one hierarchy boundary per pinch on boards,
closed covers and documents. Open notebooks stay fitted to the physical viewport;
pinching or two-finger translation neither zooms nor closes their page. Two-finger
Undo, three-finger Redo and horizontal page turns retain their own recognizer routes. Release
chooses the nearest endpoint; reversal and cancellation use the same portal
projection. A waiting/retired transition cannot accept a late preparation callback.
The accepted location remains in the model; `SceneCameraSettlement` only animates.
Same-board preparation retains the destination body and identity while its finite
scene window follows the actual camera. It cannot replace still-visible board
sources with the future endpoint window before movement; ordinary coverage and
density thresholds schedule the next window. Cross-board demand retains its own coordinates.
A completed opening retains its original board camera in the existing return-place
history; Back restores that view instead of inventing a cover-centred zoom. A
cancelled or failed opening does not add a history entry.
Closed folders prepare their own material, not hidden child contents. The single
opening/return target shares existing scene allocation and native page readiness.

See [performance](performance.md#navigation-and-working-sets),
[scene allocation](scene-allocation-contract.md), and the separate build,
installation and physical acceptance results in [verification](verification.md).
