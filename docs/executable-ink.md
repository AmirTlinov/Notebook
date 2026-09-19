# Executable handwriting: source and offline dependencies

## Product boundary

MyScript is excluded: no SDK, certificate, paid API or deferred licensing dependency.
The intended recognizer must be open or owned, offline on iPad and based on actual
ink. Apple Vision for Python and an open two-dimensional math model are investigated
routes, **not a completed integration**. Recognition quality is not sufficient for
automatic execution.

The intended interaction remains indicate → Compute → compact result, with details
on demand. Pencil UUIDs/points are the source; recognized text is not a second
independently editable document. No nonfunctional product button is added.

## Implemented source/candidate storage

`NotebookComputation` belongs to a physical notebook/page. Activation stores region,
ink version and immutable page order in addressed `PageDocument.computations`
records through the same store/journal. Deletion tombstones its UUID; late replies
cannot revive it. Ordinary element edits do not assign computation state another
agent clock.

`readComputationInk` reads bounded original pen/eraser UUIDs and samples in painter
order. Inactive actions affect source identity but are not drawn. Crossing strokes
remain complete and are clipped by the renderer rather than given invented endpoints.
PNG baselines are explicitly unsupported as editable Pencil points. This source read
is not yet connected to a production OCR renderer.

`beginComputationRecognition` fixes attempt/source. Publication checks attempt,
record version, ink clocks and SHA of addressed values; equal clocks alone are
insufficient. New pen/eraser/undo rejects a stale answer without harming input.
Retries after ambiguous commit do not duplicate delivery; stop/delete are versioned.

Candidates are always saved as **requiring review**, even when unique and syntactically
valid. Python case, indentation, whitespace and lines are preserved.
Bindings validate UTF-8 boundaries and source UUID/sample ranges; missing bindings
mean whole-region recognition, not fictitious character precision. Publication grants
no execution authority.

Any ink edit anywhere on the page conservatively invalidates prior interpretation
during the addressed snapshot read. Limits: 8 MiB addressed data, 4,098 rows,
65,536 page points; at most 256 computation records including tombstones.
Exceeding recognition limits does not block stop/delete. Listing checks ink identity
once rather than rereading it per computation.

Core tests use synthetic real-format ink and explicitly supplied candidate text,
not a fake recognizer passed off as OCR. The actual persistence-queue harness checks
input-before-read, stale answer rejection, later stroke preservation and stopped
attempts without using installed stores.

## Offline execution experiment

[ComputationResources](../Applications/ComputationResources/README.md) pins Pyodide
314.0.6 / CPython 3.14.2 and four scientific libraries, about 35 MB.
It is **not linked into app targets**. The isolated computation harness uses one
headless WKWebView and one Worker; a new run terminates the old worker. It receives
no archive/NOTEBOOK_HOME, invokes no MCP/helper and runs with system network denial.

A custom URL scheme serves exact immutable resource names. CSP plus system network
denial rejects HTTP(S), WebSocket, file URLs and traversal. WebKit uses Blob modules
from pinned bytes and loadPyodide.createPyodideModule; its inactive scheduling policy
allows real headless work without pretending a visible window. This is Mac evidence,
not physical iPad execution.

Historical checks exercised fractions, algebra/calculus, NumPy/SciPy and high-precision
math; bounded output, real Python errors and terminating an infinite worker.
A local TexTeller 3 ONNX q8 candidate matched only three of five demonstration strings,
misreading a chemical formula and a coefficient. Warm recognition around 0.20–0.25 s
and roughly 1.59 GB process RSS were Mac observations, not calibrated OCR accuracy
or iPad resource figures. Example training overlap was unknown.
Cold scientific Python startup took 8–14 seconds in that run.

## Remaining limitations

- WebAssembly floating-point exception behavior differs from native libraries:
  the observed singular inverse returned NaN rather than LinAlgError. Strict JSON
  rejects nonfinite output; native exception parity is not promised.
- WASM declares up to 4 GiB memory. A worker timeout is not a hard application memory
  cap or evidence that arbitrary computation is safe for production.
- OCR has no proven stroke-level symbol alignment, calibrated confidence or
  Torch/native-preparation parity. Syntax/numerical agreement is not recognition
  accuracy.
- Handwritten Python indentation/case, physical ink/eraser/undo, background lifecycle,
  UI review, persistent trace, shared Python context and computation export remain
  unimplemented or unaccepted.

The next integration must reuse the existing source versions/writer while adding
bounded offline physical-input recognition and explicit ambiguity handling.
It cannot substitute a second content owner or use test success to authorize
installation.

[Historical profiles, negative full-run result and raw output paths](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/executable-ink.md).
Current evidence: [verification](verification.md).
