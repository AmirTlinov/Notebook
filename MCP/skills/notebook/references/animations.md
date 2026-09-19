# Scientific and educational animation

Motion can explain a transition between states: a changing field, a moving signal,
an algorithm, or an emerging form. Pause, seek, and meaningful parameters help
the reader examine and compare those states.

`animation` saves HTML/SVG and JavaScript as a board/page `web` element or a
document `interactive` block. Code and initial state remain in Notebook beside
the surrounding material.

## Starting point

See the [scientific examples](scientific-examples.md) for complete explanations.
[assets/animation](../assets/animation/) contains a smaller traveling sine wave
with a point at fixed x: play/pause, quarter-cycle steps, phase, amplitude, and
speed. Reuse its time controls or replace `sample()` and `draw()`.

Copy `wave.html`, `wave.css`, and `wave.js` beside `input.json`:

```json
{
  "target": {"kind": "page", "id": "PAGE_ID"},
  "title": "A wave and a moving point",
  "htmlPath": "wave.html",
  "cssPath": "wave.css",
  "javaScriptPath": "wave.js",
  "initialState": {"phase": 0, "amplitude": 1, "speed": 1},
  "offset": {"x": 40, "y": 80},
  "width": 760,
  "height": 560
}
```

For a board use `target.kind:"board"` and `anchor`. For a document use
`target.kind:"document"` and optional `afterID`; block height is 48–2,048.
Inline `html`, `css`, and `javaScript` strings can replace paths.

```sh
node ~/.codex/skills/notebook/scripts/prepare.mjs animation input.json request.json
node ~/.codex/skills/notebook/scripts/animation-preview.mjs request.json preview.html
# Publish once the scene is ready and publication is intended:
node ~/.codex/skills/notebook/scripts/submit.mjs request.json
```

The self-contained preview sends nothing to Notebook and resets state on reload.
An existing scene's parameter changes usually need only `setElementState` or
`setBlockState`. Use [file-backed programs](programs.md) for TS, imports, large
assets, and workers.

## Authoring a scene

`html` is a body fragment with inline SVG/canvas and controls. Styles and code
are separate fields. Inline images use data URLs; network libraries and local
file paths inside HTML cannot load. Embed SVG directly instead of using
`<object>`, which is unavailable. SVG animation can use `pauseAnimations()`
and `setCurrentTime()`.

Browser programs receive `notebook.state`, `notebook.commit(next)`, and
`notebook.ready(promise)`. Declare ready after the first intended frame.
External state arrives through `notebookstate`. The example saves explicit
human changes to phase and parameters; playback is local and frames do not
create writes. An external state change stops playback at the received moment.

The model owns motion; the visual representation explains it. Name important
simplifications and distinguish schematic displays from measurements. Inspect
the phases and transitions on which the explanation depends.

## Lifecycle

Executable JavaScript must declare readiness under `NotebookProgram/1`.
A missing declaration, rejected promise, or timeout is a local failure.

Register `notebook.lifecycle({pause, checkpoint, resume, dispose})` once:

- `pause`: stop clocks, workers, and audio.
- `checkpoint`: return the complete JSON state of the shown moment.
- `resume`: restore operation after return or a recoverable failure.
- `dispose`: release resources.

Async hooks receive `{signal}`; an operation has a four-second deadline.
Late completion cannot write. The native owner confirms persistence before
release. Checkpoints serialize model state, not the JavaScript heap.
Types are in [notebook-browser.d.ts](notebook-browser.d.ts), separate from
QuickJS `nb`.

The LC example uses `lc.html`, `lc.css`, and `lc.js` in
[assets/animation](../assets/animation/). Feed them to the same recipe.
Suggested frame: 900 × 760, or 760 × 720. Charge, current, and energy derive from
one phase in an ideal lossless model. Fields are qualitative, playback is slowed,
and parameters have SI units. Pause, quarter-period steps, reset, and parameter
changes save explicit state; frames do not.

Local preview uses the same JS bridge with a local adapter. For a separately
installed skill, set `NOTEBOOK_PROGRAM_BRIDGE` to the absolute
`WebResources/notebook-program.js` path from the build being examined.
`notebook.version` exposes the API version. Preview does not establish
WebKit/iPad acceptance.
