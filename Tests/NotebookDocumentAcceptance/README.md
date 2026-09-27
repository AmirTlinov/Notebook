# LaTeX document acceptance on the installed pair

Use the separately paired private acceptance Mac/iPad, never write fixtures into
Amir's current workspace or restore a historical archive. Install the same build
on the Mac and physical iPad. A Simulator is not physical acceptance; use one only
when explicitly selected.

## Author through the public owner

Run `create-control.js` as `notebook_execute start` source. It uses SDK v2 snapshots,
`nb.board`, `nb.id`, and one `nb.transaction`; it does not open SQLite or rewrite
native files. Keep its run/document/board/action IDs and full terminal output.

The bounded control contains fourteen real files, not generated Markdown blocks:

- complete `main.tex`, a local class/style, and five included chapter files;
- a vector PDF image at `figures/control.pdf`, plus a `.bib` read by BibTeX;
- real section/figure labels, references, citations and two-column text;
- 540 × 720 bp pages and one 720 × 540 bp page, controlled by LaTeX;
- HTML/CSS/JavaScript/manifest for a stateful oscillator;
- a fixed illustration inside `figure`, and a distinct `breakable` instance in
  normal flow. Its six numbered viewport bands distinguish continuations.

The script confirms only saved source and two addressed reads. It does not assert
successful compilation, program execution, delivery, iPad display or performance.
Source is below 50,000 characters; the retired 140-block workload is not an
acceptance requirement for this file model.

`NotebookDocumentAcceptanceUITests` opens the real generated document using:

- `NOTEBOOK_ACCEPTANCE_MANIFEST`: the isolated paired workspace manifest;
- `NOTEBOOK_ACCEPTANCE_DOCUMENT_ID`: the returned document UUID;
- `NOTEBOOK_ACCEPTANCE_DOCUMENT_TITLE`: default `Notebook canonical control`.

The editable source witness is `fileID:introduction`, path
`chapters/introduction.tex`. Outward/returning links remain «К дальней главе» and
«К оглавлению». No test should infer destination page numbers from old fixtures.

## End-to-end route

1. Confirm creation, read directory/structure, make an addressed agent patch and
   run `documentCheck` using the document owner's current revision. Preserve the
   exact buildID and inspect that build with `render(expectedBuildID:…)`.
2. On the physical iPad, open the received document. Check PDF sizes, links,
   figures, bibliography and file/line navigation. Receipt and actual display are
   separate observations.
3. Switch «Лист → Код → Рядом», choose the introduction, type and save a marker.
   Make a concurrent same-file agent change: keep the human draft on conflict.
   Verify independent-file edits and Undo do not replace adjacent files/state.
4. Move each oscillator's slider. Turn quickly through continuation pages in both
   directions, rotate, change layout, return from Code and close/reopen. Confirm
   different viewport bands, independent instance states and no lost first gesture.
5. Run `export-control.js` with `{documentID,marker,fileID:'introduction'}`. It refuses
   a missing marker before export and reports the saved program state observed.
   Later calls with `{jobID}` read the durable job; `queued` is not a saved PDF.
6. Inspect exported PDF pages, text, links and selected program state. Repeat with
   `{documentID,marker,format:'package'}` for one `.notex`. Transfer it, then import
   offline using `submit.mjs /absolute/path/document.notex`. The importer creates
   a new copy without executing its programs. Check files, saved state and cached
   print reuse; open the program explicitly before testing its interaction.

Export's receipt is the authoritative immutable source/state cut. The state read
just before admission is a witness, not permission to assume no concurrent change.

## Final unchanged-build acceptance

Run ten repetitions of the touched scenarios and thirty minutes of joint work on
one final unchanged build. Exercise focus, keyboard, fast actions, orientation and
offline operation. Collect system frame pacing/dropped frames, CPU/GPU and memory
for the actual workload; CADisplayLink or a readiness receipt is not an FPS meter.

`DocumentPresentationRecorder` observes request → content → installed native
surface. Its 5 ms polling target is not timing accuracy: MainActor delay is included.
Each page visit needs a fresh request/installation record; old receipts cannot be
reused. These times do not establish touch-to-photon or system-frame performance.

Preserve source/build identity, paired manifest, start/resume logs, exact compile
and export IDs, device delivery/display evidence, screenshots, traces and xcresult.
Record the actual result and limitations in [verification](../../docs/verification.md).

## Existing trace coordinator

`system_trace.TraceHandshake` coordinates per-process Time Profiler segments for
its supported explicitly selected environment. It verifies PID, executable UUID,
launch identity and a unique public `--notify-tracing-started` notification before
acknowledging STARTED. UI sends END before process termination and waits for CLOSED.
Recording death, identity mismatch or missing handshake fails explicitly.

Retain `.trace`, original TOC, workload intervals, identities and errors. Unknown
schemas remain `captured_unassessed`; a recognized TOC alone is not assessment.
The coordinator does not measure dropped display frames. Its synthetic lifecycle
checks can be run separately when that coordinator changes:

```sh
python3 -m unittest discover -s Tests/NotebookDocumentAcceptance -p test_system_trace.py -v
```

Fixture authoring has an isolated IPC check in
`MCP/test/acceptance-files-ipc.test.ts`. That check does not run TeX, export pixels,
program gestures or a physical device and cannot replace the route above.
