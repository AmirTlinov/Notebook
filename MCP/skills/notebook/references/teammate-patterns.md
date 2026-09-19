# Teammate patterns

Choose these like gestures in a conversation. One pointer and a short observation
are often enough.

## Look here

“Here the feedback returns to the input.” A brief highlight connects words to
an object. `args.reference` is an already known current reference:
`id`, `target`, `revision`, `label`, and optionally `elementID` or `region`.

```js
const {view} = (await nb.presentation({})).data;
return await nb.present("look-here", {
  view,
  steps: [{attention: [args.reference], duration: 3, transition: 0.2}]
});
```

The gesture leaves content, camera, and human selection unchanged. It ends
automatically or when the person touches the surface.

## This region

Use a temporary arrow or outline for an unstructured region.
`args.bounds` is a known board-world region:
`{origin:{tileX,tileY,localX,localY},width,height}`.
For an object with a reference, the highlight above is usually simpler.

```js
const {view} = (await nb.presentation({})).data;
const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 140">
  <path d="M24 108 Q120 112 216 32 M190 35 L216 32 L208 56"
    fill="none" stroke="#2E7DFF" stroke-width="3"
    stroke-linecap="round" stroke-linejoin="round"/>
</svg>`;
return await nb.present("pointer", {
  view,
  steps: [{svg, bounds: args.bounds, duration: 3, transition: 0.2}]
});
```

Adapt the path to the intended point, or use an `ellipse` for an outline.
The SVG disappears with the gesture.

## First here, then there

“Here the signal begins; here we see its effect.” Give `present` two attention
steps, roughly two seconds each, to connect two visible parts of a diagram.

## My interpretation

Use `nb.point(key, {contextID, replyTo, references})` to retain an interpretation
alongside its source. Put the explanation in the reference's `label`, for example
“This loop appears to represent a delay.” It becomes a reply in the fragment's
history.

## Leave a note here

For a persistent arrow, label, or outline, add an editable `graphic` in a
transaction. Attached connector ends follow their nodes. Keep the action's
`actionID` for selective undo.

Choose a temporary gesture for immediate attention or persistent content for
continued work. A `sent` response confirms sending; `nb.presentation({id})`
can confirm presentation when the task needs that distinction.
