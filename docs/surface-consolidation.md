# Portable Notebook surface

`NotebookSurface` owns tiled coordinates, camera trajectories, rectangular
manipulation, pen pressure and incremental measured/predicted ink geometry.
`NotebookCore` exports those same types in its content API; its
`InkRenderBounds` only converts the portable envelope to CoreGraphics.
Native Metal consumers use the extracted implementation directly.

`NotebookSurfaceWasm` marshals bounded numeric buffers into that module.
`MCP/panel/swift-surface.ts` owns the browser instance and buffer lifetime.
Its WASI adapter supplies clocks, randomness and diagnostic output; it grants
no files, sockets or process environment. Content commands and SQLite remain
with the native persistence owner.

The browser input adapter retains measured PointerEvents and projects them into
the physical owner. Predictions never enter a command. The WebGPU adapter paints
Swift's compact nodes with the same strip/caps, premultiplied blend and MSAA as
Metal; ordinary samples update only the changed tail. Contact and GPU capacities
grow together, and device recovery replays the retained prepared geometry.

`notebook_panel_edit` saves a pen contact through the existing native action
owner: one `appendInkStroke`, stable action/stroke UUIDs and empty `sources`.
Human contacts commute; addressed undo preserves other contacts. Page commands
read the named stroke and drawing header. The disposable `page_ink_order` index
supplies the complete painter frontier without reading older measurements.
Human admission preserves native widths and page-edge measurements, up to
65,536 samples. Agent admission retains its existing limits and read basis.

## Build and first host gate

Use the official **Swift 6.4.0 release**, separate from Xcode's compiler, and
the matching `swift-6.4.0-RELEASE_wasm` SDK. Set `NOTEBOOK_SWIFT` to the release
toolchain's `usr/bin/swift` when it is not on PATH. SDK installation:

```sh
swift sdk install https://download.swift.org/swift-6.4.0-release/wasm-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_wasm.artifactbundle.tar.gz \
  --checksum f07b7be3c586d92d7a07051fc6d303b87ebea67eadc40640ba59d5a8b79aa86d
npm --prefix MCP ci --ignore-scripts
node MCP/build-surface.mjs
node MCP/test/surface-parity.mjs
node MCP/test/surface-host/build.mjs
```

Native verification and pair builds prepare the WASM stage before invoking
Xcode. Its sandboxed bundle phase reads `NOTEBOOK_SURFACE_STAGE` and checks the
module against the current Swift inputs and byte digest; it never launches
SwiftPM inside Xcode's script sandbox. A direct Xcode build requires
`node MCP/build-surface.mjs` first. Pair snapshots reuse the checked stage from
their original checkout. `node MCP/test/surface-stage.mjs` exercises this boundary.

The last command prepares an isolated temporary MCP plugin in
`.build/surface-host-plugin`; it never opens a Notebook store. Register its
**absolute path** with `codex plugin marketplace add`, install
`surface-host@notebook-surface-verification`, then open its verification tool
in the real Codex panel. Remove that plugin and marketplace after acceptance.
The resource bundles all code and WASM bytes; it performs no network fetches.

The host check exercises the real Swift camera, WebGPU rendering/readback,
an opaque-origin program with verified UTF-8 labels, and a text field for manual IME/focus checks.
Neither a successful build nor a standalone browser proves Codex support.
The parity check compares the actual native and WASM camera and ink outputs,
including address limits, memory growth and refusal without partial writes.
Bulk migration waits for this gate and the physical iPad scenario in
[GUI-475](https://linear.app/main-cluster/issue/GUI-475).
The panel still uses native raster coverage. Its published checkpoint carries
separate read/change cursors and a finite scene witness. A waiting MCP request
validates short metadata after durable commits or new pixels from used leaf
resources; it holds no WAL snapshot while idle. Observation has its own bounded
IPC admission and cancellation joins its handler. Local camera and gestures
continue independently. Addressed `SceneDelta` and the remaining shared tools
form the following C2 slice. Card geometry and painter order come from
the native scene independently of raster separation. Empty ink cells are omitted
only after an addressed occupancy proof; empty SQL reads remain in the final
pixel witness, while uncertain or claimed content retains its paint cell.
The runtime is now packaged inside the plugin;
`NotebookRuntimeLifecycle` owns its process, while `NotebookApplicationLaunch`
owns admission, the workspace catalog and persistence recovery. The panel opens,
creates and selects spaces through `runtimeStatus` / `runtimeWorkspace`; those
bootstrap commands never fall through to a store command dispatcher.

## Panel identity and updates

One sealed `panel-bundle.json` contains the compiled panel, embedded WASM,
plugin version and content-derived cohort. The opener publishes its versioned
resource URI; the signed sidecar and plugin package verify the same artifact.
All private panel commands check that cohort before runtime admission. A stale
card explains that a fresh Notebook panel is required and stops background work.
Already dispatched writes retain their original result and action identity;
an uncertain write remains pending until the persistence owner resolves it.
