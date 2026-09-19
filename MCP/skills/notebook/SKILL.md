---
name: notebook
description: "Collaborate in Notebook: explore material, show relationships, draw, and extend shared pages and documents through MCP."
---

# Notebook — thinking together

Notebook is a shared surface where you and Amir think together. He can point to
a fragment, continue a drawing by hand, or change your idea. Help the conversation
move forward: clarify a thought, show a relationship, offer an alternative, or
complete a useful part of the work.

Choose and combine text, drawings, diagrams, images, and programs to make the
subject easier to understand while preserving its meaning and depth.

## Choose the next useful move

Start with what the conversation and selected material already tell you. The
right scope might be a label, a drawing, or a program that reorganizes a diagram.

Point while explaining: highlight an object, draw a temporary arrow, or indicate
two parts in sequence. Leave an editable continuation when proposing an idea.
[Teammate patterns](references/teammate-patterns.md) offer a few starting points.

[Executable recipes](references/recipes.md) cover editable maps and diagrams,
SVG, plots, animations, sketches, images, and document blocks. Adapt and combine
them freely.

Take the shortest reliable path from intention to result. Reuse known data and
group related changes into one action. A successful response is usually enough
to finish. Inspect further when a meaningful uncertainty remains, such as the
readability of a new composition.

## Scientific explanations

Build the illustration around the mechanism, relationship, structure, or state
change the reader needs to understand. Preserve the essential relationships.

The [scientific examples](references/scientific-examples.md) provide working
models and source code, from waves and gears to tensor contraction. Borrow the
explanatory technique that fits the subject.

Give the phenomenon the main space. Place controls where the user changes a
meaningful condition; prefer direct interaction with the object. Use readable
labels for visible relationships and progressive disclosure for detailed
formulas, assumptions, and sources. Keep text comfortably sized. Shape and
palette should serve the model. When a reference explains through depth, motion,
or direct manipulation, preserve that technique.

Keep the interface quiet. Remove decorative panels, duplicate indicators, and
unnecessary prompts. Retain quantity names, units, and important model limits.
For a slider, prefer a thin rounded light-gray track, a darker completed segment,
and one generously sized gray circular thumb. Keep its hit area, accessible
name, keyboard controls, and visible focus. Add numbers and ticks when precise
selection needs them.

References for quantities, units, and notation:
[ISO 80000-1:2022](https://www.iso.org/standard/76921.html),
[ISO 80000-2:2019](https://www.iso.org/standard/64973.html), and the
[SI brochure](https://www.bipm.org/en/publications/si-brochure).
Applicable guidance on visual information:
[ISO 9241-112:2025](https://www.iso.org/standard/87518.html) and
[ISO 9241-125:2017](https://www.iso.org/standard/64839.html).
For technical drawings, consult line conventions in
[ISO 128-2:2022](https://www.iso.org/standard/83355.html), views and sections in
[ISO 128-3:2022](https://www.iso.org/standard/83356.html), and projections in
[ISO 5456-2](https://www.iso.org/standard/11502.html) and
[ISO 5456-3](https://www.iso.org/standard/11503.html).
Use these references where relevant. Claiming compliance requires checking the
applicable requirements in the standard itself.

Make axes, units, scales, arrows, and visual encodings understandable. Use more
than color to convey important differences. Distinguish physical space, state
space, and data indices: a cube of tensor components alone does not explain its
relations. Identify observations, calculations, hypotheses, and schematic
representations, including their important assumptions.

Drive related animated views from one state and timeline. In an LC circuit,
charge, current, fields, and plots must describe the same instant. Carrier
redistribution should remain physically intelligible. Explain slow motion,
exaggeration, and symbolic movement. Let the reader pause at meaningful stages;
the explanation should remain useful without continuous motion.

After the final visual edit, inspect the result at its working size and, for an
animation, at representative states and transitions. Check both legibility and
scientific correctness. State the inspection boundary if rendering is unavailable.

## Technical foundation

`notebook_context` reads material. `notebook_execute` runs JS/TS with `nb`,
`args`, `emit`, and `emitImage`. `notebook_import_program` stages a file-backed
program package; publication is a separate transaction. Use `nb.help(topic)`
for an unfamiliar SDK method. Read objects and blocks by address and expand
large results only as needed.

Reads return `data` and a ready-to-use `basis`. Pass it as `base` to
`nb.transaction(key, {base, summary, operations})`. Notebook checks versions
and saves atomically. Resolve conflicts in the context of the person's latest
work. After disconnection, `resume` with the same `run_id` retrieves the result
without repeating execution.

An old message's source preserves that moment in the conversation; the current
surface may have changed. Saving, device receipt, and actual presentation are
distinct outcomes. Verify the outcome that matters to the request.
