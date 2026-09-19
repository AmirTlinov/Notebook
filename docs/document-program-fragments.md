# Programs across physical document pages

## Source modes and suspension

Switching Paper → Code hides paper without closing the document. On iPad,
`DocumentProgramOwner` pauses and retains its WebKit context; the Mac iframe owner
does the equivalent. Independent text edits preserve unchanged programs.
Returning waits for the shared writer's checkpoint acknowledgment. Canceling a UI
task does not cancel that accepted write. On failure the model stays frozen with
an addressed retry and retains its heap. Only an accepted checkpoint permits
pressure-driven eviction. Return without eviction resumes the same instance.

## File-backed packages

A web element or interactive block may reference `programPackage`, the SHA-256
of a canonical `NotebookProgramPackage`. It is atomic with source/kind in the
causal content field; changing it invalidates old checkpoints. State and geometry
remain independent. Package sources have empty inline HTML/CSS/JavaScript/source.
An explicit null removes the package and can simultaneously supply inline content.

A manifest contains sorted unique relative paths, fixed MIME, lengths and ordered
4 MiB part hashes. Limits: 1 MiB metadata, 4,096 files, 16,384 parts.
The package hash binds the namespace, not a fictitious flat-file digest.
Existing reads stream windows up to 1 MiB from the SQL SHA store.

`prepare.mjs program` hashes files outside QuickJS. `submit.mjs` calls typed
`notebook_import_program` and reports terminal status; cancellation stops between
parts. Its descriptor path is a trusted local file capability, not browser access
or a choice of Notebook store. Ready means admitted bytes, not publication/display.
`prepare.mjs animation` then creates an ordinary atomic transaction referring to
the package without embedding source bytes in arguments.

`NotebookProgramAssets` is a URL adapter on the existing WebKit owner. Each launch
gets a random `notebook-program://<capability>/` origin and only manifest-listed
paths. Native metadata and HTML/JS/assets are streamed. GET/HEAD, one byte range,
MIME, Content-Length/Content-Range/416 and bounded reads share one reader.
There are at most 64 concurrent readers. Revocation stops new callbacks/reads and
waits at most for the current bounded read. Source replacement revokes capability;
state or geometry changes do not.

CSP allows only the package origin, required bootstrap and explicitly admitted
data/blob types. External network, arbitrary files, forms and nested frames are
closed. Every resource, including workers, receives the CSP header.

`document-program.js` is the Mac inline/package transport adapter;
`notebook-program.js` owns the public API. Only a native-minted package origin
receives allow-same-origin with allow-scripts so Worker retains that origin.
It never inherits the file parent's origin; navigation to file URLs is blocked.
Inline children remain opaque. Source replacement/removal/closure revokes the
namespace, while independent text editing preserves it.

## Canonical physical slots

Program height is in PDF points (`bp`), not TeX `pt`. Breakable slot rows contain
full-width boxes and zero-width struts. SyncTeX recognizes those rows and retains
their real coordinates/heights. A continuation's `sourceOffset` is the sum of
preceding fragment heights, not a page number or footer's inherited source line.
The same decoder serves screen and export. See [cut admission](document-program-cuts.md).

## iPad owners and native handoff

`DocumentPagePresentationOwner` owns paper preparation, composites and handoff.
`DocumentProgramOwner` owns per-program runtimes, state, pause and checkpoint jobs.
Paper waits only for programs relevant to its demand.

One `DocumentBlockRuntime` executes a block ID/source version in one WebKit.
`DocumentProgramOverlayHost` mounts its full viewport behind a native clip.
Retained continuations share the same context; paper coordinators and typesetting
never start hidden copies. A passive neighbor borrows exact viewport cuts without
resizing, reparenting or disabling the current program. Ready controls accept their
first gesture while neighbors prepare. Local preparation/failure/retry occupies only
the affected region. Native contact, focus and page turns retain placement.

Visible geometry determines runtime demand through the existing
`SceneRenderResources` pool. Document demand comes from native page clipping,
ordinary paper from `PagePresentationNativeView`, and boards from the admitted
spatial cohort. Camera motion projects existing planes first, then updates demand.
Accepted touch and focus pin active programs.

The shared pool defaults to six WebKit surfaces, at most two background surfaces
and reserved input/preparation capacity; live input programs are not passive work. Other visible programs show local resource waiting, not a
false ready image or an extra Run button. Real lease release wakes queued demand;
availability generations replace timer polling. Queue time does not consume the
eight-second execution deadline after admission. JavaScript failure releases the
faulty executor and offers an addressed retry, preserving accepted explicit state.
Admission identity includes document and block IDs, and snapshots borrow that same
executor. Input coordinates are never retained for later replay.

Distant-link handoff installs prepared paper even with programs; runtimes mount
afterward. A broken program does not block reading text. Full curl composites
require all program pixels, but their failure does not poison later live paper.
Save confirms canonical paper; a block action confirms that block; a full-page
receipt covers all sources. Image, runtime and input readiness stay distinct.

## Lifecycle and durable state

NotebookProgram/1 is shared by spatial WebKit, iPad blocks, Mac iframes and preview;
only transport adapters differ. The API is installed before authored HTML.
JavaScript must declare `notebook.ready`; all declared promises count.
Missing declaration, rejection or a hung promise cannot succeed. Static HTML
needs no declaration. The author owns scheduling, pause and disposal of resources.

Pause stops new commits, invokes authored `pause` and `checkpoint`, then obtains
complete JSON state. Native admission checks exact causal source/state versions
and persists through the shared writer before capturing the stopped viewport.
The original WebKit remains mounted until one native transaction replaces it with
the clipped image; contact/focus postpones that handoff.

I/O or lifecycle failure retains the runtime and retry. A causal rejection caused
by source replacement, deletion or newer state retires the obsolete heap without
overwriting accepted state. Late completion rechecks source, current demand and
input. Return after eviction restores source identity and `notebook.state`, not an
arbitrary JavaScript heap.

State application checks the local commit counter in JavaScript and again after
the native asynchronous reply. Old optimistic echo cannot roll the counter back.
`onStateChange` acknowledges admission, not disk. `onStateCheckpoint` returns the
accepted version after SQL, not a Boolean or optimistic SwiftUI state. Another
block's change does not conflict; ABA in the same field does.

Lifecycle timeout is four seconds in JS and independently 4.5 seconds natively,
because hidden WebKit can suspend timers. Checkpoint does not await hidden rAF.
Coalesced pause is idempotent until resume. Backgrounding, leaving and closing use
that same checkpoint path, not a periodic autosave. Native removal retains the
actual WebKit/lease through writer completion. An unloaded document is not deleted:
its final checkpoint addresses one SQL block without loading the full document.

The working window follows admitted mounted/requested pages plus one neighbor on
each side. Outside it, release follows durable checkpoint and a fresh visibility/
focus/source/contact check. A failed checkpoint does not prevent other pages opening.

## Pixels and submitted evidence

Paper without programs reuses captured pixels directly. A program composite reserves
paper, cuts and result before the first capture; sub-operations borrow that admission
rather than releasing/reacquiring bytes. Exact integer dimensions include WebKit
height rounding. Passive density follows scale within the shared pool and retries
on actual capacity release without a self-triggered loop.

`capturePresented` synchronously freezes the installed paper and native programs
at Send; PNG encoding happens later from those pixels. Hidden/uninstalled/pending
handoff surfaces report unavailable. Asynchronous `captureCurrent` captures a new
frame for ordinary image requests and cannot prove the send instant. A cached
source token alone is not evidence for a current animated frame.

Unmount releases passive raster pins even if UIKit retains its UIView. Clips remove
child WebKit references; coordinator completion also releases page fallback pixels.

## Semantic attention

Optional `notebook.semantic` returns one bounded authored object after pause/
checkpoint. It is data, not instructions or permission. Metadata shares the exact
`RasterLease` / `NotebookSubmittedPixels` with the image and is transformed from
program viewport through physical fragment into the selected crop.

Existing attention owns the explicit pause and temporarily closes native input so
scroll/pick cannot detach the anchor from its frame. Send freezes the installed
surface before releasing pause. Clear, error and disposal also release it.
Source/state/UUID guards prevent late callbacks affecting another heap or pause.
Newly accepted state releases old attention pause before applying.

Immutable `AgentPinnedSource.programSemantic` binds image SHA and reference revision.
Without proven pause, ready capture and valid callback it is unavailable, even if
visual evidence exists. It neither expands RequestGrant nor bypasses CAS.

## Portable document import

`nb.export(key,{documentID,format:"package"})` uses the same immutable export cut,
CAS and cancellation without running code or typesetting. Its artifact is
`document.package` plus unique adjacent `blob-<sha256>` V2 parts.
Copy the **whole directory**, not just the JSON. Metadata is at most 8 MiB;
publication remains bounded by 1 MiB / 16,384 parts. Complete dependency sizes and
hashes are streamed and validated before saved publication.

From the Notebook skill directory:

```sh
node scripts/submit.mjs /absolute/directory/document.package
```

The existing importer admits dependencies, then submits one ordinary
`createDocument` transaction in the current workspace. It accepts a whole source
file or explicitly addressed parts, deriving part paths only from adjacent hashes.
Retries preserve package/run/document identities; an uncertain response resumes
rather than creating another transaction. Saved block values, including JSON null,
replace initial state; old workspace causal clocks are not imported. Code remains
data until explicit opening, and camera/selection stay unchanged.

This creates a new document copy, not restoration of a historical archive.

## Evidence scope

`DocumentProgramOwnerTests` checks one context, independent neighbors/editor,
checkpoint-before-release and nine programs without enlarging the pool.
Historical September 11 failures showed repeated first fragments and duplicate
passive execution; those are superseded by the current owners above.
[Original measurements and negative evidence](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/document-program-fragments.md)
remain available. Native tests and preview do not prove physical gestures,
delivery or long-session acceptance; see [verification](verification.md).
