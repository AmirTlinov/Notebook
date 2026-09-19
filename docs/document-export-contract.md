# Document export

## One canonical owner

`DocumentCanonicalExport` reads the same `DocumentCanonicalPrint.store` artifact
used by paper. `NotebookTypesetter` owns PDF/SyncTeX layout. Printed text, paths,
formulas and links retain their canonical coordinates; only live program rectangles
need isolated authored frames. Export does not use the retired
`NotebookSandboxedTeXCompiler` / native Tectonic-helper pipeline.

`nb.export(key, options)` starts a durable job. Its `NotebookExportCut` captures
source and state in one WAL transaction; hash and state revision are recorded
before rendering. Saved export executes that cut in an isolated existing renderer
using the asset store and shared `SceneRenderResources` budget. It never checkpoints,
seeks, borrows uncommitted pixels from or rewinds the user's live executor.

## Formats

PDF is the default. All receipts use
`artifact {path, sha256, byteCount, mimeType}` and `options`; PDF additionally
provides source, assets and maps. Options participate in package identity.

| Format | Meaning |
|---|---|
| `pdf` | Canonical vector paper, with authored program-frame composition |
| `png` | One canonical page at the requested pixel width |
| `svg` | Passive authored vector frame from a named interactive block |
| `html` | One inline program and saved state as an offline standalone file |
| `package` | Portable document/source/state with complete package dependencies |
| `mp4` | Canonical page frames at explicit authored model times |

```js
await nb.export("page-image", {
  documentID, format: "png", pageIndex: 0, pixelWidth: 1600
});
await nb.export("vector-frame", {
  documentID, format: "svg", blockID: "signal"
});
```

PNG preserves the requested width rather than silently reducing it for admission.
A missing page returns `export_page_missing`, not the last page. WebKit owns only
program rectangles from the canonical map; opaque snapshot backgrounds cannot
cover neighboring printed text or formulas.

Programs declare `notebook.exportFrame(({format,state,signal}) => …)`.
The isolated runtime pauses before invoking it with the exact saved state; commits
are disabled. For raster output, the author stops clocks, awaits model/media work,
draws the target backing Canvas/WebGL at the supplied CSS pixel ratio and returns
null once ready. Missing callback returns `program_export_unavailable`, not an
arbitrary startup frame. Admission precedes backing-size growth; normal native
capture/composition follows. Timeout or disposal aborts the operation.

SVG uses the same callback with vector output. It accepts up to 1 MiB of closed,
passive SVG using literal presentation attributes/local definitions. Scripts,
foreignObject, CSS styles, animation and external resources fail explicitly.
There is no raster fallback disguised as SVG.

Standalone HTML is at most 8 MiB and is not executed during export. Explicitly
opening it runs NotebookProgram/1 in an opaque offline sandbox iframe without
file-origin or Notebook-writer access. Local changes do not return to Notebook.
Modules/package assets require portable export and return
`export_portable_required` rather than a broken file-URL bundle.

Portable output is `document.package` (`NotebookPortable/1`) plus adjacent
`blob-<sha256>` files. **Copy the entire containing directory.**
It does not run programs or typesetting. Source/state/manifest metadata is limited
to 8 MiB; unique V2 parts remain at most 4 MiB. Import is described in
[program fragments](document-program-fragments.md#portable-document-import).

MP4 uses one isolated coordinator and authored timeline, not screen recording or
a second animation engine. An off-main AVFoundation receiver consumes sequential
frames with backpressure. Output is H.264 without audio, using model times
`[start,end)`; odd height is padded white. Working buffers use the existing pool.

A submitted **presented PNG cut**, when supplied, exports the exact retained
presentation crop with original pixels and extent: no new WebKit frame, checkpoint,
rescale or cache read. This is different from rendering a saved-state page.

For `moment: "presented"`, supply `attention:{contextID,referenceID}`.
PNG takes the original crop, without page/block selectors or resolution changes.
Other formats require the same source and a frozen program checkpoint bound to
those pixels; mismatches return `export_presentation_model_unavailable` or
`export_presentation_mismatch`. Whole-document/page formats (PDF/package/MP4)
reject other interactive blocks without that checkpoint. A selected block's frozen
state cannot label unrelated running models as presented.

MP4 requires an even width of 128–4,096, 1–60 FPS and an integral 1–3,600 frames.
Saved PNG accepts widths 128–4,096 (default 1,600), subject to resource admission.

## Atomic publication and cancellation

Quartz writes composed PDF to a private file. Artifact/assets use existing V2
4 MiB parts, each checked and admitted through the writer FIFO so small edits can
run between parts. Preparation reads windows up to 1 MiB, verifies complete file
hashes/source/map off the writer, then submits a short native CAS/move/receipt
transaction. Publication metadata is limited to 1 MiB / 16,384 parts. Canonical
typesetter limits still apply to its own artifact.

The writer rechecks the entire source/state cut, including causal metadata.
Concurrent edits return `revision_conflict`; old output is never relabeled current.
Package identity includes `document.cut.json`. Failed/stale/canceled preparation
removes its temporary directory and preserves prior exports.

`nb.cancelExport(key,{jobID})` persists cancellation and its keyed effect atomically,
then stops the producer. Final publication rechecks cancellation even after a late
callback. Once the saved receipt has passed the writer fence, that immutable receipt
wins over late cancellation. Status/retry/restart never revive canceled jobs;
repeated reads validate existing files by streaming.

There is no binary `publishExport` IPC path or oversized base64 PDF command.
Saved identifies that captured cut, not perpetual freshness after future edits.
Ready, saved, delivered and shown are separate facts.

## Verification

Check publication identity/CAS/cancellation in Core, authored frames and composition
in native export tests, and the actual rendered artifact for the affected format.
Structural TeX assertions alone do not establish a correct PDF.
Current limits and print ownership: [canonical paper](document-page-fragments.md).
Exact release results: [verification](verification.md).
