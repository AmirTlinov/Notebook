# Scientific examples

The library contains six inline JS/SVG explanations and three asset-backed
programs. They are original educational implementations inspired by Amir's
chosen references; source links and attribution are in
[examples.json](../assets/science/examples.json) and each scene's disclosure.

Each scene explains a bounded mechanism. For example, `gears` is a rotatable gear
train with an opening support, and `gaussian` demonstrates one GP regression
model. Their scope is narrower than the reference articles.

| Example | Model | Main relationship | Recipe |
|---|---|---|---|
| `sound` | Longitudinal wave | Displacement / compression / propagation | `animation` |
| `gears` | 3D gear train | Tooth count / angle / direction | `program` |
| `linear` | Linear transformation | Matrix / basis / oriented area | `animation` |
| `gaussian` | RBF Gaussian process | Observations / covariance / uncertainty | `animation` |
| `astar` | A* search | Obstacles / frontier / shortest path | `animation` |
| `tensor` | Matrix contraction | Indices / components / sum | `animation` |
| `probability` | Bernoulli trials | Probability / outcomes / frequency | `animation` |
| `signal` | Dense sampled signal | Extrema / selected samples / formula | `program` |
| `wave` | Numerical membrane | Boundaries / propagation / computation | `program` |

## Explore before adapting

Run the local gallery in a task-owned output directory:

```sh
node ~/.codex/skills/notebook/scripts/science-preview.mjs /absolute/task/preview
# Open /absolute/task/preview/index.html while the process is running.
```

Rerunning updates generated files; do not target a directory of authored HTML.
Inline examples use `animationPreview`; `gears`, `signal`, and `wave` use
`program-preview` with the same assets and browser bridge. Package servers bind
only to `127.0.0.1`. Stop them with Ctrl+C after inspection. Preview needs no
Notebook connection or external network after dependencies are prepared, and
state lasts until reload. External references open only when selected.

- `sound`: follow one particle and compare it with compression.
- `gears`: orbit, raise the support, and compare marked wheels.
- `linear`: seek a projection to its endpoint and inspect the collapsed area;
  drag a basis vector to change a matrix column.
- `gaussian`: add an observation, change correlation length, and compare the
  covariance matrix with the uncertainty band.
- `astar`: block the passage and inspect both a route and a no-path result.
- `tensor`: select an output component, step through k, and edit an input.
- `probability`: compare short/long sequences and the p = 0 / p = 1 limits.
- `signal` and `wave`: follow the data and lifecycle checks in
  [programs](programs.md).

The model occupies the main field. Keep only essential controls initially
visible; disclose covariance matrices, secondary parameters, and model limits.
Keep explanations readable. Reserve color for meaning. The dark coordinate
space in `linear` is specific to that scene.

`gears` uses Three.js/WebGL 2 with real three-dimensional glTF geometry and a
depth buffer. It replaces the earlier inline renderer. Orbiting and opening the
support preserve gear ratios and playback. Visible keyboard focus and direct
selection are part of the interaction. This is an educational scene, not CAD
or a friction solver.

## Publish in Notebook

For an inline example:

```json
{
  "example": "gaussian",
  "target": {"kind": "page", "id": "PAGE_ID"},
  "offset": {"x": 40, "y": 80},
  "width": 960,
  "height": 960,
  "initialState": {"length": 0.8, "noise": 0.12}
}
```

```sh
node ~/.codex/skills/notebook/scripts/prepare.mjs animation input.json request.json
node ~/.codex/skills/notebook/scripts/animation-preview.mjs request.json scene.html
# Only when writing to the selected surface is intended:
node ~/.codex/skills/notebook/scripts/submit.mjs request.json
```

Boards require `anchor`; documents use `target.kind:"document"` and optional
`afterID`. Choose height from the actual narrow-column render, keeping text
readable. Inline requests retain all HTML/CSS/JS. Explicit human actions save
state; animation frames do not. Received state stops playback at that state.

Asset-backed examples use `prepare.mjs program` with `{"example":"gears"}`,
`signal`, or `wave`, then the [two-phase publication](programs.md#publication)
path. A prepared or staged package has not yet been shown in Notebook.

## Reuse the explanation

[assets/science](../assets/science/) contains inline scene HTML/JS, shared
`models.js`, `runtime.js`, and `common.css`, plus the packaged examples'
directories. Models own calculations; scene code connects models to rendering;
the shared runtime owns state, controls, and local time. It does not replace
Notebook's host runtime. Model checks live in `MCP/test/science-examples.test.ts`.

Adapt the nearest example in your own working copy. Inline adaptation supplies
`htmlPath`, `cssPath`, and `javaScriptPath` instead of `example`. Include
required models, shared runtime, then scene code in the JavaScript, and the
necessary common styles in CSS.

Examples start without autoplay. Preserve meaningful limitations: normalized
quantities in `sound`, matrix interpolation in `linear`, and pointwise rather
than simultaneous uncertainty intervals in `gaussian`.
