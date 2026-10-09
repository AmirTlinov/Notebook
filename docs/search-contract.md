# Search source and recipe

Item titles, native text, Markdown source and document file source are literal
text: angle brackets and markup-like words stay searchable. Native graphics
contribute their label while geometry is visible. Groups, hidden graphic
tombstones and ink representations contribute no label.

An HTML-only fallback extracts structural text without a DOM, CSS, execution or
resource loading. Quoted attributes, comments, script/style, head and template
bodies are excluded. Inline boundaries join text; block boundaries add a space.
Textarea/title use raw text with entity decoding. Common named entities and
numeric Unicode entities decode once; unknown names stay literal. Unfinished
markup bodies are discarded from the derived text, while literal `< 2` stays.
Source and output each admit at most 8 MiB; exclusions nest at most 256 levels.
Limit refusal rolls back the operation without truncating authored content.

Local database version 29 admits recipe 1 in the existing writer transaction.
Version 28 rebuilds only searchable physical envelopes, one at a time; no whole
document, page or source tree is reconstructed. Index rows, recipe marker and
admission version commit together. Source hashes, causal fields and read/delivery
cursors remain unchanged. Current admission verifies the recipe marker.

Each new connection registers the constant `notebook_search_recipe()` capability.
Search-entry insert/update/delete triggers require it, including FK cascades.
A handle opened by an old writer before migration cannot silently change the
new index. Search cursor format 2 refuses continuations from the old recipe.
Wire 44 and manifest 26 are unchanged.

Exact document-file references reuse the existing addressed file/version
projection. `NotebookDocumentFileReference/1` binds document ID, file and its full
causal source version; sibling
files, aggregate document stamps and program state do not enter it. A complete
document reference retains its complete source/state contract.
Old document-file hashes described an aggregate document/state cut and differ
from a fresh addressed reference. Saved contexts, pinned source cuts and action
receipts remain inspectable and are never rewritten; live reads never guess an
old hash from the current aggregate.

Native source Save requires `PreparedDocumentSourceEdit`: the exact editor cut,
workspace and recipe output are prepared on a utility worker before entering
the existing writer. One unaccepted preparation reserves at most 64 MiB,
leaving room for the ordinary 192 MiB Pencil reservation in the shared 256 MiB
admission budget. Cancellation and shutdown join that worker before releasing
its credit. The completed plan shrinks to its retained cost while human input
settles; its writer finish is acquired immediately before FIFO transfer.
Accepted tails share the existing queue and do not occupy the preparation slot.

The writer checks workspace, recipe, literal input seal and causal source CAS.
Source, derived index, action and terminal draft receipt publish in one SQLite
transaction. A peer ABA or changed workspace cannot install the old plan.
An accepted plan and its result remain owned through an uncertain COMMIT and
Retry. Other content commands use the same search preparation and installation
synchronously; this native Save slice does not move their work out of the writer.

Admission accepts the compact file causal vector and refuses retained register
bodies before Task capture. The prepared finish bounds the selected prior draft,
file projection and same-session action before any oversized blob body is read.
An unfinished old draft releases its body before the projection phase. A large
old envelope can refuse a small direct Save; the editor first persists its latest
draft through the same FIFO. Source comparisons preserve exact Unicode bytes in
editor changes, CAS, delta, drafts and Undo/Redo.

`CollaborationWorkspace` retains at most one typed document during a source-action
segment. Every JSON `files` write invalidates it; an accepted edit restores its
validated material and the metadata written by the existing field-change owner.
The candidate is released before publication, lifecycle barriers and receipts.
Initial/final SQL source cuts and the published, source-free receipt header remain
independent reads. The command never retains a typed cache for every document.

The local receipt publisher carries one typed receipt and its already encoded
JSON through the synchronous physical writer. Reuse requires an exact whole root,
literal keys and strings, matching number bits and exactly represented typed
integers. The index binds to that root's written hash. Incoming or ineligible roots
retain the same typed validation; no material survives the command.

For one original document-source change, that material also carries the fresh
field digest. The index and frozen result reuse it only for the same file, path
and literal UTF-8 source. Freeze still reads the hash-bound SQL model and refuses
a different indexed digest; the index never supplies the result's digest. Undo
and unmatched fields compute the digest of their actual written value.

The isolated NB10 probe is `NotebookSearchIndexCostTests` with
`NOTEBOOK_SEARCH_TRACE_BYTES=1024`, `1048576`, or `4194304`, once per process.
It traces actual BEGIN IMMEDIATE→COMMIT, VM steps, allocator live memory, SQLite
memory and a competing accepted ink command. PROFILE tracing preserves the
progress handler. Sampled live allocation peaks are distinct from total
allocation events; RSS high water includes fixture setup.
In Debug, `publicationCodec` counts actual document/receipt decodes and
document/files/receipt encodes and source-digest passes, borrowing required buffers
without a measuring encode. `NOTEBOOK_SEARCH_TRACE_SQL_MEMORY=0` disables per-statement memory probes
for latency attribution; unobserved SQL peak fields are omitted. SQL trace/VM
counts and competing ink remain. Reduced codec work alone does not establish
lower latency.

Allocation admission scans borrow raw JSON bytes and existing contiguous UTF-8;
bridged strings retain a scalar fallback. The byte coefficients, cumulative
transaction credit, caught-refusal latch and cancellation every 4096 bytes remain.
Readers observe cancellation; an accepted writer keeps its completion lifetime.
