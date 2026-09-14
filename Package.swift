// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "Notebook",
  platforms: [
    .iOS(.v27),
    .macOS(.v27),
  ],
  products: [
    .library(name: "NotebookCore", targets: ["NotebookCore"]),
    .library(name: "NotebookCodex", targets: ["NotebookCodex"]),
    .library(name: "NotebookScriptHost", targets: ["NotebookScriptHost"]),
    .library(name: "NotebookScriptWorker", targets: ["NotebookScriptWorker"]),
    .executable(name: "notebook-codex-proof", targets: ["NotebookCodexProof"]),
    .executable(name: "notebook-bridge", targets: ["NotebookBridge"]),
    .executable(name: "notebook-ipc-test-host", targets: ["NotebookIPCTestHost"]),
    .executable(name: "notebook-archive-transfer", targets: ["NotebookArchiveTransfer"]),
    .executable(name: "notebook-acceptance", targets: ["NotebookAcceptance"]),
  ],
  targets: [
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
    .target(name: "NotebookCore", dependencies: ["CSQLite"]),
    .target(name: "NotebookCodex", dependencies: ["NotebookCore"]),
    .target(name: "CQuickJS", path: "Sources/CQuickJS",
      exclude: ["LICENSE", "UPSTREAM.md"],
      sources: ["quickjs.c", "dtoa.c", "libregexp.c", "libunicode.c", "cutils.c", "notebook-quickjs.c"],
      publicHeadersPath: "include",
      cSettings: [.define("CONFIG_VERSION", to: "\"2026-06-04\""), .define("_GNU_SOURCE")]),
    .target(name: "NotebookScriptProtocol"),
    .target(name: "NotebookScriptWorker", dependencies: ["NotebookScriptProtocol", "CQuickJS"], exclude: ["Resources"]),
    .target(name: "NotebookScriptHost", dependencies: ["NotebookScriptProtocol", "NotebookCore"], resources: [.process("Resources")]),
    .executableTarget(name: "NotebookCodexProof", dependencies: ["NotebookCodex", "NotebookCore"], path: "Tests/NotebookCodexBridgeHarness", exclude: ["receipt.json"]),
    .testTarget(name: "NotebookCodexTests", dependencies: ["NotebookCodex"]),
    .executableTarget(name: "NotebookBridge", dependencies: ["NotebookCore"]),
    .executableTarget(name: "NotebookIPCTestHost", dependencies: ["NotebookCore"], path: "Tests/NotebookIPCTestHost"),
    .executableTarget(name: "NotebookArchiveTransfer", dependencies: ["NotebookCore", "CSQLite"]),
    .executableTarget(name: "NotebookAcceptance", dependencies: ["NotebookCore"]),
    .testTarget(name: "NotebookCoreTests", dependencies: ["NotebookCore"]),
    .testTarget(name: "NotebookScriptHostTests", dependencies: ["NotebookScriptHost", "NotebookCore"]),
    .testTarget(name: "NotebookScriptWorkerTests", dependencies: ["NotebookScriptWorker", "NotebookScriptProtocol"]),
    .testTarget(name: "NotebookArchiveTransferTests", dependencies: ["NotebookArchiveTransfer"], resources: [.copy("Resources")]),
  ]
)
