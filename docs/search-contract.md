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

The isolated NB10 probe is `NotebookSearchIndexCostTests` with
`NOTEBOOK_SEARCH_TRACE_BYTES=1024`, `1048576`, or `4194304`, once per process.
It traces actual BEGIN IMMEDIATE→COMMIT, VM steps, allocator live memory, SQLite
memory and a competing accepted ink command. PROFILE tracing preserves the
progress handler. Sampled live allocation peaks are distinct from total
allocation events; RSS high water includes fixture setup.
