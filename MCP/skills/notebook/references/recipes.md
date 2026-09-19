# Recipes at hand

These are adaptable building blocks. Choose their form and combination around
the source material and the intended result.

| Recipe | Result |
|---|---|
| `mindmap`, `flow`, `compare` | Editable native nodes and attached connectors — [diagrams](diagrams.md) |
| `visual`, `plot` | Saved images or SVG, including imagegen output — [visuals](visuals.md) |
| `program` | TS/imports/CSS/assets/workers compiled into an offline package — [build and preview](programs.md) |
| `animation` | Interactive HTML/SVG on a board, page, or document — [animation](animations.md) |
| `sketch`, `point` | Native ink or temporary attention — [visuals](visuals.md) |
| `document` | Selected blocks in a new or existing document — [documents](documents.md) |

The [scientific examples](scientific-examples.md) cover sound, mechanisms, linear
geometry, uncertainty, search, tensor contraction, and probability. Larger
asset-backed examples use the same package pipeline.

## Prepare and submit

Save the selected inputs in `input.json`, then run:

```sh
node ~/.codex/skills/notebook/scripts/prepare.mjs mindmap input.json request.json
```

The resulting file contains ordinary `notebook_execute` arguments: code, data,
and a stable `run_id`. Pass the whole file to that tool. A file client keeps
image bytes out of conversation text:

```sh
node ~/.codex/skills/notebook/scripts/submit.mjs request.json
```

It calls the same public API through the installed Mac owner's MCP and returns
its response. Continue with the saved request and `run_id`; use the ordinary
tool's `resume` operation when needed.

Common inputs are `target`, a board `anchor` or page `offset:{x,y}`, and optional
`summary`, `contextID`, and a previously read `base`. A supplied basis is used
unchanged; otherwise the recipe reads only destination headers. One composition
is saved in one transaction. The response includes its `action` and semantic
part `ids` for targeted edits and undo.

`prepare.mjs` only prepares a file. The published result lives in Notebook and
can be changed through any ordinary SDK program. The
[generator](../scripts/recipes.mjs) exposes layout, spacing, labels, and
connections as ordinary functions.
