# Canonical printed pages and native source editing

`DocumentDocument` owns Markdown, `latex` formulas, full `tex`, preamble and
interactive blocks. Existing commands and causal undo persist them. Markdown is
converted to TeX for typesetting only; there is no independently editable reverse
conversion.

## One print layout

`NotebookTypesetter` compiles an immutable document to PDF and SyncTeX off the main
actor. `NotebookPrintedDocumentStore` shares jobs and maintains a bounded 128 MiB
derived disk cache keyed by resource version and complete source. PDF, source and
map are checked on read. Canceling the last reader stops the real job; canceling
one shared reader preserves the others.

`DocumentSourceSnapshot` has one `DocumentPagePreparation` containing PDF,
SyncTeX addresses, links and accepted `DocumentLayoutRecord`.
`DocumentPrintedSource` shares that map with paper and editor. Arbitrary TeX
requires whole-document compilation; native content loading also currently reads
the whole document. Independent prefix pagination is not promised.

After WebKit admission, the existing frame sender starts PDF preparation alongside
shell loading; only frame delivery waits for the shell. Cancellation/retirement
ends that wait, and runtime/generation/source are rechecked before sending.

`DocumentPaperSize` defines A4 (210×297 mm) or Letter (8.5×11 in), in PDF points
(72/in). `WorkspaceItemGeometry` defines placement, not font size. MediaBox is
validated before publication. Zoom, camera, rotation and raster density do not
retypeset. `DocumentPaperView` draws that PDF through Quartz. WebKit supplies links,
addressed regions and live programs, not duplicate text or HTML pagination.
The former measurement DOM and `document-fragments.js` are removed.

iPad paper and programs retain `DocumentPagePresentationOwner` and
`DocumentProgramOwner`; see [program fragments](document-program-fragments.md).
Independent text edits preserve unchanged programs.

## Source editing

Code and Side-by-side initially show the exact assembled LaTeX read-only.
Interactive blocks are explicit in safe TeX comments: inline HTML/CSS/JavaScript
and initial state, or an immutable package SHA-256. TeX reserves their physical
space; Notebook executes the code. The same menu opens real package files or
inline source, without making an editable duplicate. Text is paged in UTF-8-safe
256 KiB chunks; binary files show metadata. Block/program sources remain accessible
when typesetting is unavailable.

`DocumentSourceEditorSession` edits an addressed field against its original version.
`DocumentNativeSourceEditor` uses UITextView/NSTextView, syntax highlighting,
system search, completion and UTF-16 ranges. Input never waits for compilation.
Debounced `commitDocumentSource` autosaves; text typed during a write becomes a new
draft on the **accepted** version. Idempotent retries return the original accepted
version, including after SQL reopen.

IME composition remains a draft until complete. Draft text, selection and scroll
survive conflicts or block deletion. Comparing/replacing with a new source requires
an explicit user decision. Human edits, agent edits, additions and undo share one
command owner; native text widgets have no independent document undo history.

Portrait iPad offers Paper and Code; landscape also offers Side-by-side. Rotation
from split to portrait preserves source/cursor. Keyboard appearance does not
change mode availability. Code mode neither admits paper input nor claims paper
visibility.

Double-tapping printed content resolves the nearest TeX line or original Markdown
paragraph through SyncTeX from the **installed PDF**. A newer model cannot relabel
old pixels. Source selection can navigate to paper or share its exact text, range
and verified version with the agent. A macro may resolve to a nearby fragment,
not an individual character.

While compiling or on failure, retain the last successful print with explicit
status. Install new paper only when fully ready. `DocumentSavePresentation`
distinguishes saved from installed. Native drafts do not enter the PDF.

## Runtime and resource limits

Both platforms use the same AOT WebAssembly engine and pinned fonts, without JIT,
shell, network, SQLite or user-filesystem access. Cancellation checks exist in
generated TeX/font/image/BibTeX/PDF code; traps do not cross Rust/Swift frames.
WASI exposes only admitted resources.

| Resource | Limit |
|---|---:|
| VM linear memory | 320 MiB |
| Virtual files / one file / descriptors | 64 MiB / 32 MiB / 128 |
| Job, including queue / log | 30 s / 64 KiB |
| Normalizer memory / stack / CPU | 64 MiB / 1 MiB / 2 s |
| PDF / compressed SyncTeX / expanded SyncTeX | 16 / 4 / 16 MiB |
| Pages | 4,096 |
| Page raster | 8,192 px per axis, 16 megapixels |

Impossible requests fail explicitly. Fifteen seconds idle or memory pressure releases
an unused engine. `SceneRenderResources` accounts for decoding, maps, messages and
rasters; JSON includes styles, programs, state and causal versions. Reservations
last through actual completion, including callbacks. Quartz/PDFKit draw cannot be
interrupted mid-call: bounded dimensions and cancellation prevent publication,
while the real owner keeps its lease until return. Accounting limits are not RSS
measurements.

Raster density follows visible projection. Hidden preparation and 256 px thumbnails
retain only their requested density; exact snapshots reserve their own extent.
Density changes invalidate the same sender generation. Hidden owners release
replaced rasters before admission; visible paper keeps old pixels until replacement.
Showing paper sharpens the existing artifact without recompilation.

## Position, export and receipts

`DocumentReadingPosition` is a device-local semantic anchor: block, nearest source
line, offset and scale relative to fit. Page number comes from current layout.
Deletion resolves through prior order; an unavailable map is not deletion.
Navigation confirms installed paper, not a loading UI.

[Export](document-export-contract.md) shares the canonical artifact and immutable
source/state cut. Exact raster evidence binds token, generation and installation
epoch. Ready means an artifact is available, not that it was shown on iPad.
Historical DOM receipts are not rewritten or reused as current renderer evidence.
See [verification](verification.md).

Math placeholders use one collision-safe token map and one-pass restoration.
Heading destinations, literal code, assets and source ranges restore the same
exact TeX; export does not repeatedly scan the output for each formula.
