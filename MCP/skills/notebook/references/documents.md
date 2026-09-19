# Writing document blocks

`prepare.mjs document` writes the supplied text using the structure you choose.

- New document: `target:{kind:"board",id}` and a board `anchor`.
- Append: `target:{kind:"document",id}` and an optional known block `afterID`.
  Existing blocks remain intact.
- `sections` contains blocks in order. Each may specify `id`, `body`, or
  `sourcePath` relative to the input JSON. The actual text is stored.
- Optional `heading` adds a level-two Markdown heading.
  `kind` defaults to `markdown`; choose `latex` for a TeX block.
- Optional `title` creates a title block; `subtitle` supplements it.
  `paperSize` and `preamble` configure a new document's print layout.

Change a previously read block with `updateBlock`; `nb.export` produces a PDF
by default. See [programs](programs.md#export) for interactive export.
