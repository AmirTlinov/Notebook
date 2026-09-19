# Images, SVG, and sketches

Use the available `$imagegen` for illustrations and `$svg-diagram-design` for
precise SVG composition. Notebook remains the shared working surface. Insert
the resulting file directly:

```json
{
  "target":{"kind":"board","id":"BOARD_ID"},
  "anchor":{"tileX":0,"tileY":0,"localX":600,"localY":400},
  "imagePath":"/absolute/path/illustration.png",
  "width":720,
  "caption":"The relationship this illustration makes visible",
  "fit":true
}
```

Pass this input to `prepare.mjs visual`. PNG, JPEG, and SVG bytes are embedded
in an ordinary Markdown element and saved with it; temporary paths are not
needed afterward. SVG stays vector-based. `imagePath` may be relative to the
input JSON.

For a large PNG/JPEG, `fit:true` writes a reduced derivative beside the request
while preserving format and PNG transparency. The original is unchanged.
Embedded images are limited to 700 KB to fit the SDK's request budget together
with code and data. Choose an appropriate scale or separate fragments for
fine details.

`plot` creates a small SVG plot from actual data. Replace `imagePath` with:

```json
{"title":"Measurement","xLabel":"Time, s","series":[
  {"label":"Trial A","points":[[0,2],[1,4],[2,3],[3,6]]},
  {"label":"Trial B","points":[[0,1],[1,2],[2,4],[3,4]]}
]}
```

Include the usual `target` and placement. Other scientific graphics can use
custom SVG through the same insertion path.

`sketch` takes `strokes:[{points:[{x,y,width?,opacity?}],width?,color?}]`.
These become native ink. Board points are offsets from `anchor`; page points
are page-local.

`point` takes current `references:[...]` or board-world
`bounds:{origin,width,height}`. `shape:"ring"` draws an outline; the default is
an arrow. `duration` controls the temporary presentation. Content and camera
stay unchanged. See [teammate patterns](teammate-patterns.md).
