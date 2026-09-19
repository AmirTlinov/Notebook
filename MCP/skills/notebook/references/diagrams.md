# Maps, diagrams, and comparisons

`mindmap` lays out a tree left to right and sizes nodes for their labels.
For an already selected page:

```json
{
  "target":{"kind":"page","id":"PAGE_ID"},
  "offset":{"x":40,"y":80},
  "tree":{"id":"question","label":"Why did the result change?","children":[
    {"id":"observations","label":"Observations","children":[
      {"id":"before","label":"Before"},{"id":"after","label":"After"}
    ]},
    {"id":"explanations","label":"Possible explanations"}
  ]}
}
```

For a board, replace `offset` with a known
`anchor:{tileX,tileY,localX,localY}`. Each object's coordinates are normalized
separately. `nodeWidth` controls width; `gap` controls branch spacing.

`flow` takes `nodes:[{id,label,shape?}]` and `edges:[{from,to,label?}]`.
Use native shapes, such as `diamond` for a decision. Feedback edges are retained
as curves. Dense diagrams may benefit from editing the generated coordinates or
using a custom layout.

`compare` takes `columns:[{id?,title,body}]` and optional `columnWidth`.
The result is a row of movable, editable cards.

In the response, `ids.observations` identifies the corresponding native node.
Read it by address, then use `updateElement` for the intended field or add adjacent
nodes. Preserve the person's existing composition changes.

Mermaid can serve as a textual sketch. These recipes take a tree or explicit
nodes and edges; they do not parse Mermaid. Insert an externally rendered SVG
through `visual`.
