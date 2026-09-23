# Verification record

This record separates code checks, installed builds, live readback, and physical
acceptance. Linear owns task state. Results apply only to their named source and
environment; later changes do not inherit acceptance automatically.

## GUI-297 — notebook and document covers, September 23, 2026

This isolated slice starts at `9332808851e28136ee75dfde667a0b667140b2d2`.
Cover material and printed typography now have one owner; handwritten/content
layers and title-independent raster caches remain separate. Notebooks have light
paper tones, a subtle same-colour fold and the Russian notebook imprint, without
a contrasting spine. Document title pages display their actual A4/Letter format.

The notebook's shared 834×1194 geometry now uses an 18-point continuous corner,
between the rejected 8 mm and 2 mm variants. The nominal radius comes from the
installed Apple 11-inch iPad Pro (3rd generation) device profile, which includes
the physical iPad13,4; no Simulator was launched. This is a shared native contour,
not a claim of measured pixel-for-pixel equivalence to a hardware display mask.

Final application/test input SHA-256:
`9051da678f40175646b462069f9d4284da4bdd9138491dfd0549c380fe4812e9`.
Core **2/2** passed (paper identity, notebook geometry and whole-sheet zoom).
Mac **3/3** passed (cached pixel reuse, all six notebook tones, short and long
document titles). Physical iPad Pro 11-inch, iOS 27.0 (24A435), **2/2** passed:
ordinary double-tap entry and ink travelling with the opening cover. No skips,
failures or runtime warnings were reported by the native runs. Native Mac title
renders and the iPad curl screenshot were inspected.

Evidence: `.build/gui297-radius-core/tests.log`,
`.build/gui297-radius-final/verification.json`,
`.build/gui297-radius-render/` and `.build/gui297-radius-cleanup/`.
Before the final notebook-radius-only correction, A4 and Letter cover/page bounds
also passed opening/closing in both orientations on the physical iPad:
`.build/gui297-covers-final/verification.json`, input
`877c5443706db3aa9d4b80a5f71caf601354f1499a7bcda20bfa1a63aca569d8`.
Document geometry and styling were unchanged by that correction.

Earlier diagnostic runs remain in `.build/gui297-covers-a/` and
`.build/gui297-covers-b/`: an unrelated standalone-text accessibility lookup did
not match the aggregated PDF page, and the first render assertions rejected
coloured typography and an ellipsized maximum-length title. The focused render
checks now measure readable printed ink; long titles keep a readable minimum
size. No document renderer or interaction threshold was weakened.

Only isolated native-test applications were installed, and both iPad test
applications were removed after verification. Production Mac/iPad applications,
content and identities were not replaced. Integration into the current GUI-295
branch, a production pair update and Amir's visual acceptance remain pending;
these scoped checks do not establish full performance or hardware-Pencil
acceptance.

## Current recorded state — September 19–20, 2026

- Latest completed installed pair recorded here: **0.3.131 (134)** on Mac and
  physical iPad, source commit `3fc651d4`, wire **37**, content manifest **18**.
  Its exact receipt is below.
- GUI-266's lasso-selection lifecycle follow-up is installed and awaits
  Amir's physical user acceptance; scoped checks are not full acceptance.
- GUI-240 is **Done by Amir's explicit decision**; its integration is complete.
  Remaining GUI-250 performance/long-session conditions were not declared passed.
- GUI-183, GUI-196, and GUI-197 remain In Progress in Linear as checked on
  September 19 at 22:18 UTC. Their scoped evidence remains useful; broader
  acceptance is tracked independently.
- Documentation translations do not change application behavior. Source-directory
  Markdown belongs to the build inventory, so this documentation revision has a
  different input identity from earlier installed releases.

## GUI-266 follow-up: lasso selection survives scene publication — build 134

Source commit `3fc651d45662975749dc81dd58161cf541309384` is pushed. Immutable input SHA-256: `351d62d13e7ae42797cc0a5f1e72d64644c455d15db47669532f3f2b91862450`. The signed pair retains wire 37 and manifest 18.

- Reproduced the reported Pencil outline without retained selection in the mounted native scene: an older SQL scene cut discarded accepted lasso selection while its ink conversion was still being written. The existing accepted-working-graphic owner now retains it until exact publication; no new selection state or fallback was added.
- A second, independent `AgentOverlayView` callback cleared the selection from its rendered element list even after the conversion had saved. Its removal leaves reconciliation to the model instead of two competing owners. A captured diagnostic stack identified this callback; temporary logging was removed before the final run.

Final unchanged-source verification: **physical iPad 34/34**, zero failures/skips, runtime warnings empty. The mounted-scene regression blocks the SQL writer, completes lasso through the installed Pencil recognizer, publishes the older scene, then releases persistence and verifies the same selection and geometry survive. It includes 27 pen strokes and a long self-intersecting eraser, preserving the original ink journal. Native coverage also exercises type filters and accepted moves; device UI gestures cover selected-object drag, edge taps, zoom/camera pan and page curl. The retained selection screenshot was inspected. Pencil contacts in the native regression are synthesized on the physical device, not hardware Pencil acceptance. No simulator was used.

Diagnostic runs remain recorded: A corrected a missing notebook pin in the regression setup; B reproduced the original premature deselection; C/D isolated the remaining view-owned reset after the model fix. Final evidence: `.build/gui266-lasso134e/verification.json`, `.build/gui266-followup134/attachments-e/`, `.build/gui266-build134/build.json`. A read-only copy of live page ink was separately selected and saved in isolated stores; it was not a production-content mutation or a live UI acceptance claim.

Mac and physical iPad were updated in place to **0.3.131 (134)** and launched at about **23:05 UTC on September 19**. Amir explicitly authorized interrupting active work; ordinary AppKit shutdown completed without forced termination. Mac store/spaces/registry/activation bytes before relaunch and the iPad workspace registry digest were preserved. Installed versions were read back on both devices. Fresh installed-helper readback at cursor **25774** matched baseline **25753** for the checked page and board data/content/ink revisions. The installed iPad screenshot shows the existing user notebook and ink. Receipt: `.build/gui266-install134/installation.json`. GUI-266 user acceptance, hardware Pencil feel and full performance/long-session acceptance remain open.

## GUI-266 follow-up: page gesture ownership and large selection — build 133

Source commit `8d02d9469e1122f10b52461e629fad173822da4f` is pushed. Immutable input SHA-256: `993a14ae101f3bc556ee4eef5c60cac11a24e4ccd2b8901927c3bdfc372400a6`. The signed pair retains wire 37 and manifest 18.

- UIKit's curl now waits for contact admission before beginning, instead of being cancelled after it has already started. Selected-object manipulation, editing and zoom own their contacts. System edge-tap page turns are disabled. Curl playback is 1.8 times faster while transitioning, with ordinary layer timing restored afterwards.
- The existing one-finger camera owner now also pans zoomed paper, constrained by the reading camera. Selected graphics own their visible selection envelope; erased graphics retain exact remaining-paint hit testing.
- Viewport-sized figures are no longer excluded from selection. Measured-ink point picking uses the retained triangles directly rather than building a pathological overlapping stroked path; chronological erasure and transformed geometry remain intact. Raw-ink selection budgets were not changed.

Final unchanged-source verification: **physical iPad 40/40**, runtime warnings empty; **Core 4/4**. Real device UI gestures exercise selected-object drag, both edge taps, pinch zoom, one-finger camera pan, return to fit, forward/reverse curl and the existing inline text/formatting/layer flow. Screenshots were inspected. A 60,000-vertex Core picking regression completed in 14 ms. Synthetic native contacts do not establish hardware Pencil feel; no simulator was used. Diagnostic runs A/B remain recorded: a recognizer-reset assumption and UI pinch targeting/near-fit precision were corrected in the tests, without weakening production admission thresholds. Final evidence: `.build/gui266-selection133c/verification.json`, `.build/gui266-followup133/core.log`, `.build/gui266-followup133/attachments-c/`, `.build/gui266-build133/build.json`.

Mac and physical iPad were updated in place to **0.3.130 (133)** and launched at about **22:37 UTC on September 19**. The first normal Mac quit waited at its active-work confirmation and timed out before replacement; it was cancelled. Amir then explicitly authorized interruption, and the ordinary AppKit shutdown completed without forced termination. Mac store/spaces/registry/activation bytes before relaunch and the iPad workspace registry digest were preserved. Installed-helper readback at cursor **25133** matched baseline **25126** for both checked pages and the board's content/ink revisions. The installed iPad screenshot shows the existing user notebook and ink. Receipt: `.build/gui266-install133/installation.json`. User acceptance, hardware Pencil feel and full performance/long-session acceptance remain open.

## GUI-266 follow-up: one layer menu — build 132

Source commit `f7e3b25b3d77f6fb7e56b293bae508d3fd5e1b4b` is pushed. Immutable input SHA-256: `33530e103e28b9c8d6d209df5b600eceab377246dbcc3b1f960c1045167a935a`. The signed pair retains wire 37 and manifest 18.

- One layer button opens four textual actions: one layer down/up and all the way to the bottom/top. iPad and Mac share one action enum and native command owner; old front/back callbacks were removed. The complete durable painter order, not the viewport, determines the result. Stable ordering within selected groups, undo and exact-source admission are preserved.
- The first physical UI check exposed a separate text jump during keyboard dismissal. Finger displacement was measured relative to a moving SwiftUI anchor. The recognizer now measures displacement in its stationary window, while hit resolution remains scene-local; an active text editor cannot start an object drag.

Final verification: physical iPad 8/8, Mac 1/1, runtime warnings empty. The iPad UI scenario executes all four menu actions, formatting, selection and finger drag, checks edge-disabled actions, fitted bounds and unchanged paper/ink. Screenshots were visually inspected. A native regression keeps the finger stationary while the layout moves, then verifies the exact physical drag delta. Core 5/5 includes all four moves on page/board, offscreen membership, reopening, undo, stale-source rejection and a 100,000-ID ordering pass. No simulator was used. Initial diagnostic failure remains recorded in `.build/gui266-selection132`; final unchanged-source success is `.build/gui266-selection132b/verification.json`.

Other evidence: `.build/gui266-followup132/core.log`, `.build/gui266-followup132/attachments-b/`, `.build/gui266-build132/build.json`.

Mac and physical iPad were updated in place to **0.3.129 (132)** and launched on September 19 at about 21:59 UTC. Receipt: `.build/gui266-install132/installation.json`. Mac store/spaces/registry/activation bytes before relaunch and the iPad workspace registry digest were preserved. Fresh installed-helper readback at cursor 24243 confirmed the two checked pages and board content/ink revisions unchanged from the pre-install baseline. Installed iPad screenshot was inspected; the existing user notebook is shown. GUI-266 physical user acceptance and full performance/long-session acceptance remain open.

## GUI-266 follow-up: lasso and text selection — build 131

Source commit `df490a0203790c5b41ab1635391a83c8d44714f4` is pushed. Immutable input SHA-256: `74c6fef051ee0b2e987509362e7816747df8f3102ff08a82276908190f58124d`. The signed pair includes GUI-183, GUI-240 and GUI-273 (wire 37, manifest 18).

- Lasso now rasterizes measured triangles in bounded batches instead of constructing a pathological overlapping CoreGraphics path. Ink projection uses the graphic's source budget instead of a second, obsolete 16-stroke limit. A read-only copy of 48 live ink actions reproduced both failures; isolated probes selected 27/21/5 strokes in 62/74/147 ms and saved each conversion. These timings describe selection calculation, not durable write completion.
- Native text uses one fitted geometry for rendering, hit testing, selection and manipulation. The duplicated drag projection was removed on iPad and Mac. Legacy oversized text frames can commit a move.
- Both text-selection contexts have one clipboard menu with textual Cut/Copy/Paste actions. UIKit owns inline paste. Native-text A| is removed; layer order is exposed in the primary selection bar.

Final checks: physical iPad 12/12, Mac 1/1; runtime warnings empty. Core DrawingToolsContent 5/5 includes conversion of 27 strokes, reopening, original ink preservation and undo. Native scene checks exercise the installed Pencil recognizer with measured, synthesized Pencil contacts; this is not hardware Pencil calibration. UI checks exercise real selection, formatting, finger drag, copy/paste/cut and visually inspected fitted bounds. Diagnostic runs A/B exposed a legacy-frame commit mismatch and a system paste-permission interruption; these were resolved before the immutable final run C. No simulator was used.

Evidence: `.build/gui266-selection131c/verification.json`, `.build/gui266-followup131/core-c.log`, `.build/gui266-build131/build.json`, `.build/gui266-install131/installation.json`. Mac and physical iPad were updated in place to **0.3.128 (131)** and launched on September 19 at about 21:31 UTC. Mac store/spaces/activation/registry bytes before relaunch and the iPad workspace registry digest were preserved. Fresh installed-helper readback at cursor 23608 confirmed both page content/ink revisions and the board content revision unchanged. The installed iPad screenshot shows the existing user page and ink.

At that receipt GUI-266 was In Review for Amir's normal Pencil use on that page.
Full physical/performance/long-session acceptance was not claimed.

## Recent integrated releases and milestones

Detailed original attempts, failures, raw identifiers, and local evidence paths
remain in the
[immutable journal through commit 1723ec2b](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/verification.md).
The summaries below preserve scope; they do not reclassify historical failures.

### GUI-183 — remote Codex integration, September 19

Merge `5a8f3960` integrated `fdfb6eb7` into `e9716207`, retaining the
current editor, typesetter, and account-owned bootstrap. Wire became 37;
content manifest stayed 18. The pair requires coordinated updating.

Immutable merge checks: Core/Codex 7/7, Mac 3/3, physical iPad UI 1/1.
The actual UI opened the fourth of four 60 KB requests and addressed all four
decisions. Its screenshot showed the full request, command, and buttons.
A real isolated `notebook-acceptance prepare-device` check confirmed shared
account credential, portable iPad root, and separate Mac bundle.
Evidence: `.build/gui183-merge/native-20260919/verification.json`,
`core.log`, `portable-bootstrap.json`, and `approval-render/`.

That merge did not itself install production or prove WAN operation. Later
build 131 included it. GUI-271's backend setup/repair and tool-filter preservation
were exercised with real signed Codex 0.155.0 and isolated state. Its Mac setup
button's direct UI click remained unverified after ScreenCaptureKit failed.
GUI-272 dictation was intentionally left unchanged at Amir's request;
that decision does not certify the existing private HTTP/JWT route.

### GUI-266 — build 130, September 19

**0.3.127 (130)**, wire 36/manifest 18, followed integration `7841111c`.
It unified empty-text lifecycle, addressed text editing/deletion, direct object
selection, formatting/clipboard, and measured-ink selection.

Immutable source SHA:
`ef0d4891404982db0faeea78a3d245f1f71f80fef96bbc32b3e2dd01ac41dcea`.
Final physical iPad 23/23 (20 native + 3 UI), Mac 1/1, Core 15/15, MCP schema
10/10, and MCP source TypeScript checks passed. Earlier compile/UI failures
remained recorded. Synthetic UIKit Pencil contacts did not establish hardware
Pencil behavior.

Installed over 129 at 20:22 UTC with container/identity preservation.
Live readback cursor 23103 matched baseline 23097. The immediately preceding
IPC attempt was unavailable and remained a failed observation. The inspected
post-install screenshot had a lock-screen overlay; unlocked user acceptance
was not claimed. Evidence: `.build/gui266-selection130f/`,
`.build/gui266-build130/`, and `.build/gui266-install130/`.

### GUI-273 — geometric ink and preview recovery, build 129

**0.3.126 (129)** removed an observed main-thread CoreGraphics softmask stall
from automatic preview by preparing the canonical erase mask off-main.
Measured page ink stayed geometric after pen-up, settle, and reopen.
Content-digest invalidation replaced unnecessary camera-driven regeneration.

Source SHA:
`4dcd0c3104e9b93cd5eef9ace06e7bcb06ff73f2c3a9eec3af17f7c525799906`.
Physical iPad 17/17 and Mac 2/2 passed; Core scene-paint revision 1/1 passed.
The 3,603-sample Mac regression took 0.821145 seconds for preview+tile with
maximum main-actor heartbeat gap 0.011097 seconds; warm publication took
0.128907 seconds. These are scoped regression measurements, not system FPS.

Installed in place at 19:42 UTC. Readback cursor 23047 matched baseline 23040.
A later Mac document-opening gesture could not be confirmed because CUA returned
`noWindowsAvailable`. Evidence: `.build/gui273-verify129c/`,
`.build/gui273-results/`, `.build/gui273-build129/`,
and `.build/gui273-install129/`. Hardware Pencil feel, full system metrics,
ten repetitions, and 30-minute collaboration remained outside this check.

### GUI-240 — scientific visualization integration

At Amir's explicit request, GUI-240 was closed and the completed branch integrated
as `451161d7` (`17b6cc5b` into `2459e309`). Eight conflicts were resolved
while preserving document toolbar/LaTeX/program behavior and the current
library/devices/formatted-text implementation.

Integration checks in `.build/gui240-merge/`: Core 21 + 21 tests in partially
overlapping suites, MCP TypeScript plus 33 tests, Mac and iPad Simulator
compile/link. A generic iOS attempt lacked its staged device typesetter library;
the final iPad integration build used the prepared Simulator runtime.
That step did not install applications or establish a new signed release,
physical acceptance, or `verify.sh --full`.

Implemented contracts are maintained separately:
[lifecycle/packages](document-program-fragments.md),
[authoring](../MCP/skills/notebook/references/programs.md),
[canonical paper](document-page-fragments.md),
[shared attention](shared-context-contract.md), and
[export](document-export-contract.md).

Important scoped results and remaining limits:

- A 300 MiB program resource was delivered to the private Simulator and read after
  the sending Mac stopped. Staging, delivery, and actual offline display were
  recorded separately.
- Native/source/geometry checks and direct Mac/browser interactions found and
  fixed paper distortion, idle layout feedback, source/side-by-side presentation,
  program-source visibility, bottom spacing, and linear-example resize/drag.
  These successes do not erase later reader-entry UI failures.
- Final bounded-paper checks in `.build/gui250-visible-paper-v4/`:
  Simulator native 33/33, Mac native 11/11, no skips/runtime warnings.
  Inspected A4/Letter PNGs and real native curl landings are not a full UI or
  system-performance run.
- Two Sound request-to-installation observations were **1,864 / 1,174 ms**,
  not p95. The **cold ≤500 ms goal was not met**.
- The final addressed Mac reader-entry attempt
  `.build/gui250-addressed-reader-ui-v1/` built but passed **0/3 UI tests**:
  search found the cover, double-click did not establish the reader surface.
  Window title alone was insufficient. Its later UI-only WIP fixture was not
  run and was removed when work stopped.
- Full reference review, shared/recovery scenarios, system FPS/CPU/GPU/memory,
  ten repetitions, and 30-minute acceptance were not all completed for the final
  integrated GUI-240 source. Closure was an owner decision, not a fabricated PASS.

### S1–S10 programmable SDK milestone — September 18

This separate earlier milestone was accepted on production builds 105/106.
Build **0.3.103 (106)** used source `6bf6159`, retained containers and keys,
and confirmed saved/received/shown state without rerunning the prior undo.
The final surface retained human continuation `SDK count101`; cleanup removed
only the four test-created items and returned item count 7→7.

The final aggregate checked 70 scenario runs (seven × ten), 60 exact publications,
and 125 successful native summaries, excluding five failed/invalid summaries.
The original record also reports a >30-minute collaborative native/MCP scenario.
This is not a claim that every historical suite or `verify.sh --full` passed.

System traces lasted 135.816 and 300.948 seconds. The latter was a bounded
five-minute lifecycle/undo/idle recording, separate from the long collaborative
session. For Notebook PID 7976:

| Metric | Median / p95 / maximum |
|---|---|
| Physical footprint, 293 samples | 279.361 / 288.470 / 457.127 MiB |
| CPU, 292 samples | 25.681 / 72.051 / 127.697% |
| Device Core Animation FPS estimate, 298 samples | 8 / 60 / 60, including idle |
| Device hardware GPU, 298 samples | 0 / 55 / 68% |

Notebook GPU intervals summed to 854.219 ms across 817 possibly overlapping
intervals, not wall-time utilization. System display/GPU values do not establish
isolated Notebook 60 FPS or absence of hitches. Compiler memory and SDK v1/v2
comparisons were separate measurements.

Evidence: `.build/s10-complete-20260918/final-receipt.json`,
lifecycle/ink/publication receipts, final read, trace/XML, native AX/PNG, and
public requests/replies. [Measurement summary](programmable-notebook-measurements.md).
This milestone does not accept later Mac workspace, drawing, or GUI-240 changes.

## GUI-277 — English documentation and contract corrections

The September 19–20 documentation update reviewed all 87 tracked Markdown files
and changed 79. Project-owned Russian documentation is now English; existing
English upstream notices and licenses remain unchanged. No application or test
implementation changed in this slice.

Corrections cover current export formats and canonical typesetting, the three
public MCP tools, package authoring/publication, scientific-example inventory,
resource budgets, direct selection/drag, account-owned connection, and verification
scope. The retired native TeX probe is labeled historical and its missing old
runtime dependencies are explicit. Long historical journals are summarized here
with immutable links to their complete original records.

Checks: 261 local Markdown links and 11 heading targets resolve; all eight fenced
JSON examples parse; code fences are balanced; tracked Markdown contains no
remaining Cyrillic prose; Markdown diff whitespace checks pass. Referenced current
repository paths resolve; the single absent path is the explicitly retired TeX
lockfile in the historical probe guide. No native build, app installation,
physical acceptance, or external-link availability is claimed by these checks.

## Earlier history

The immutable journal above preserves all earlier release attempts and evidence,
including negative or incomplete results. Supporting English summaries:

- [September 8 audit](audit-2026-09-08.md) and
  [September 13 audit](audit-2026-09-13.md).
- [September 13 implementation series](implementation-2026-09-13.md).
- [Historical render-boundary measurements](live-document-render-boundary.md).
- [Document editor opacity check](document-editor-opacity-verification.md).
- [Data preservation](current-mac-preservation.md) and
  [retired-owner conversion](retired-owner-conversion.md).
- [SDK v1/v2 measurements](programmable-notebook-measurements.md).

Local `.build/` evidence is not guaranteed to exist in every checkout. Git retains
the report, not all large traces or application containers. An unavailable artifact
limits re-verification; its path alone cannot support a new acceptance claim.

## How to record new results

Follow [verification selection](release-build-contract.md#verification-selection)
for the smallest sufficient regression plus affected user scenario.
A receipt should identify:

1. Exact source commit and immutable input hash, build/version, platform/device,
   and any diagnostic instrumentation.
2. Executed tests and gestures, failures/skips/warnings, and the observed result.
3. Evidence paths and the boundary between simulated/native/hardware input.
4. For installation: signed artifact identity, preservation checks, launch, and
   fresh installed-helper readback.
5. Remaining conditions, separately from issue closure or merge state.

Full acceptance additionally needs system frame/CPU/GPU/memory measurements,
ten scenario repetitions, and 30 minutes of collaborative work on the named
build. Video, CADisplayLink, compiled UI, and cached pixels cannot replace the
corresponding system or physical observation.
