# Native Notebook surface

`NotebookSurface` owns tiled coordinates, camera trajectories, rectangular
manipulation, pen pressure and incremental measured/predicted ink geometry.
`NotebookCore` exports these types in its content API; `InkRenderBounds`
converts the portable envelope to CoreGraphics. Native Metal consumers use the
same geometry directly.

The iPad application owns the working surface, Pencil input, selection, tools,
text editing and navigation. Measured ink reaches the native action owner;
predictions only contribute to the displayed contact. Camera and preview changes
remain local to the gesture. Agent commands use the same content and addressed
history owners through the direct MCP server.

`NotebookPagePreparationWindow` owns the finite native source capabilities.
`PageCompositionRenderer` and `SceneCompositionRenderer` share those sources
with the resource budget and the existing memory-pressure owner. Durable page
and current-view images remain available to MCP through the native preview
publisher; they do not establish a second interactive surface.

The desktop plugin, web board, browser ABI and WASM build were removed by the
October 8 product decision. Native source checks use the ordinary Xcode/Swift
route in the [release contract](release-build-contract.md). Physical Pencil,
selection and editing acceptance remains on the iPad.
