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

One `DocumentBlockRuntime` executes a block ID/program identity in one WebKit.
`DocumentProgramOverlayHost` mounts its full viewport behind a native clip.
Retained continuations share the same context; paper coordinators and typesetting
never start hidden copies. A passive neighbor borrows exact viewport cuts without
resizing, reparenting or disabling the current program. Ready controls accept their
first gesture while neighbors prepare. Local preparation/failure/retry occupies only
the affected region. Native contact, focus and page turns retain placement.

A same-identity viewport or metadata replacement must first drain accepted state
and finish the existing checkpoint. Its replacement receives the confirmed value
and causal state version even if the presentation input has not echoed that write.
This one-shot handoff supersedes only a strict causal predecessor; newer or
concurrent input remains authoritative. Writer failure retains the same heap and
unfinished stage until explicit Retry. A source identity change still revokes the
obsolete author rather than transferring its state into another program.

An explicit background/close checkpoint keeps the program owner's execution gate
closed until an explicit resume. Geometry replacement, input publication, Retry
and release of retained attention cannot reopen it. Overlapping checkpoint/resume
requests follow the latest explicit intent through the same lifecycle jobs;
accepted state applications finish before freezing. Retry may finish a failed
freeze or write while the gate stays closed. A failed author requires Retry, not
a geometry change; a causally new author does not inherit the old heap's failure.
Paused images also retain their captured viewport dimensions: a changed width or
height invalidates the image and uses the existing preview preparation path.

Visible geometry determines runtime demand through the existing
`SceneRenderResources` pool. Document demand comes from native page clipping,
ordinary paper from `PagePresentationNativeView`, and boards from the admitted
spatial cohort. Camera motion projects existing planes first, then updates demand.
Accepted touch and focus pin active programs.

The shared pool provides `maximumVisiblePrograms + 2` WebKit surfaces, at most two background surfaces
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

`DocumentProgramIdentity` is the winning causal dot of content (including package),
CSS, JavaScript and initial state. It is not the editor's content-only source
version or an aggregate clock. Source A → B → A and delete/recreate invalidate the
old executor; height, placement, current state and another block do not.
Paused presentation metadata carries this same four-field identity. A presented
export compares it against the immutable export cut, not the text editor version:
changing CSS, JavaScript or initial state also revokes an older image's claim.
Historical immutable evidence containing only `sourceVersion` is not admitted as
this format. It is neither rewritten nor assigned an invented causal identity;
backward-compatible decoding was explicitly declined on September 25, 2026.

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
The internal `onStateChange` callback is asynchronous; the public JavaScript
`notebook.commit` remains synchronous and returns its admission Boolean. Loaded
model admission updates the addressed value immediately; both loaded and retiring
heaps obtain the actual accepted version from the same addressed SQL writer.
Neither a model no-op nor a different causal winner may attest an obsolete heap.
Both retain their FIFO entry through I/O failure; neither hydrates a whole closed
page or document. `onStateCheckpoint` returns the accepted version after SQL,
not a Boolean or optimistic SwiftUI state. Another
block's change does not conflict; ABA in the same field does.

Lifecycle timeout is four seconds in JS and independently 4.5 seconds natively,
because hidden WebKit can suspend timers. Checkpoint does not await hidden rAF.
Timeout revokes the lifecycle generation; a late authored promise cannot resume
or freeze the current generation. Retry repeats only the failed stage: a completed
pause is not invoked again after checkpoint failure, and failed resume remains
frozen with an explicit Retry on the same runtime.
The same native deadline bounds state windows, ACK, external-state application
and the close-admission boundary. Transport failure retains the head's completed
windows, accepted writer receipt, heap and admission. Explicit Retry continues
that stage in the same heap; an ACK retry is idempotent and does not rewrite state
or grant credit twice. No deadline cancels an already entered durable writer.
Checkpoint writer failure retains its frozen snapshot and basis, rather than
pulling, reserving or checkpointing it again. The writer's exact receipt is also
the loaded-model acknowledgment: there is no second full-state read/admission.
Coalesced pause is idempotent until resume. Backgrounding, leaving and closing use
that same checkpoint path, not a periodic autosave. Native removal retains the
actual WebKit/lease through writer completion. An unloaded document is not deleted:
its final checkpoint addresses one SQL block without loading the full document.

### State admission and transfer

`notebook-program.js` is the sole state owner; spatial, document and iframe code
only adapt transport. Every `commit` returning true retains an immutable JSON
snapshot in FIFO order. Neither presentation replacement nor queue compaction
may drop these writes. Overload is rejected before true, and capacity release
wakes waiting authors. A checkpoint first drains all accepted commits.
For spatial/page controls the same JavaScript owner receives native write-focus
admission. Unfocused timers return false before accepting a snapshot. The existing
trusted-input capture grants focus before the authored first click; losing focus
revokes future admission, not previously accepted writes. Passive raster jobs
reserve no unused write credit, and restarting a failed runtime cannot mistake
release of its own credit for enough capacity to recapture.

Current state has no new permanent JSON-size cap. Admission uses the existing
scene allocation budget, UTF-8 byte size and JSON node cost, including the larger
of the old and new values needed by an addressed merge. Descriptors cross the
bridge; the owner then pulls bounded, surrogate-safe windows. Native-to-JavaScript
presentation windows install atomically and may replace an incomplete older
presentation, not an accepted authored commit. Native credit is acknowledged only
after actual writer acceptance; disk failure retains the FIFO entry and its credit
through retry. Checkpoint admission similarly survives through persistence.
Each accepted descriptor captures its source basis before asynchronous reading;
the addressed writer cannot adopt a replacement source, including byte-identical
ABA. Reads, acknowledgements, credit and lifecycle calls recheck the immutable
load token inside JavaScript, because the same WebKit object can host a new heap.
Page visibility and focus never re-decide a previously accepted write.
Author readiness is independent of accepted-state ownership. Closing an unready
or failed heap closes new admission, drains posted descriptors and the native
writer, then releases the heap. It does not wait for an unresolved author-ready
promise or invoke a broken author's checkpoint again. Retry cannot cancel this
accepted tail; a source replacement still revokes the obsolete source identity.
The Mac iframe transport handshake is registered before author readiness, so
this boundary also covers an early commit whose author never becomes ready.

Internal current-state reads borrow that admission in one SQL snapshot, then
transfer immutable bytes outside the transaction. This is not a larger public
read budget: `readDocumentBlock` keeps its 4 MiB complete-result limit. Addressed page
program commands retain only that element's state and causal fields, never a whole
page/ink save. Their existing 4 MiB state-free source/header bound is independent
of the admitted current-state body. Spatial writes return the exact persisted
program-state basis, so a following checkpoint does not wait for a reload or adopt
an unrelated newer state clock.

The working window follows admitted mounted/requested pages plus one neighbor on
each side. Outside it, release follows durable checkpoint and a fresh visibility/
focus/source/contact check. A failed checkpoint does not prevent other pages opening.

## Pixels and submitted evidence

Paper without programs reuses captured pixels directly. A program composite reserves
paper, cuts and result before the first capture; sub-operations borrow that admission
rather than releasing/reacquiring bytes. Exact integer dimensions include WebKit
height rounding. Passive density follows scale within the shared pool and retries
on actual capacity release without a self-triggered loop.
Passive admission includes both the intermediate paper backing and final raster;
the hidden backing uses the admitted density instead of always requiring 1024 px.
Current-page live paper retains its requested density.

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
