# Portable Notebook surface

`NotebookSurface` owns tiled coordinates, camera transforms and canonical ink
geometry. `NotebookCore` exports those same types in its content API; its
`InkRenderBounds` only converts the portable envelope to CoreGraphics.
Native Metal consumers use the extracted implementation directly.

`NotebookSurfaceWasm` marshals bounded numeric buffers into that module.
`MCP/panel/swift-surface.ts` owns the browser instance and buffer lifetime.
Its WASI adapter supplies clocks, randomness and diagnostic output; it grants
no files, sockets or process environment. Content commands and SQLite remain
with the native persistence owner.

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

The last command prepares an isolated temporary MCP plugin in
`.build/surface-host-plugin`; it never opens a Notebook store. Register its
**absolute path** with `codex plugin marketplace add`, install
`surface-host@notebook-surface-verification`, then open its verification tool
in the real Codex panel. Remove that plugin and marketplace after acceptance.
The resource bundles all code and WASM bytes; it performs no network fetches.

The host check exercises the real Swift camera, WebGPU rendering/readback,
an opaque-origin program, and a text field for manual IME/focus checks.
Neither a successful build nor a standalone browser proves Codex support.
The parity check compares the actual native and WASM camera and ink outputs,
including address limits, memory growth and refusal without partial writes.
Bulk migration waits for this gate and the physical iPad scenario in
[GUI-475](https://linear.app/main-cluster/issue/GUI-475).
The existing panel remains active until this gate is accepted.
