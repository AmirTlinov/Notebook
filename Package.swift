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
    .executable(name: "notebook-codex-proof", targets: ["NotebookCodexProof"]),
    .executable(name: "notebook-bridge", targets: ["NotebookBridge"]),
    .executable(name: "notebook-ipc-test-host", targets: ["NotebookIPCTestHost"]),
    .executable(name: "notebook-archive-transfer", targets: ["NotebookArchiveTransfer"]),
  ],
  targets: [
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
    .target(name: "NotebookCore", dependencies: ["CSQLite"]),
    .target(name: "NotebookCodex", dependencies: ["NotebookCore"]),
    .executableTarget(name: "NotebookCodexProof", dependencies: ["NotebookCodex", "NotebookCore"], path: "Tests/NotebookCodexBridgeHarness", exclude: ["receipt.json"]),
    .testTarget(name: "NotebookCodexTests", dependencies: ["NotebookCodex"]),
    .executableTarget(name: "NotebookBridge", dependencies: ["NotebookCore"]),
    .executableTarget(name: "NotebookIPCTestHost", dependencies: ["NotebookCore"], path: "Tests/NotebookIPCTestHost"),
    .executableTarget(name: "NotebookArchiveTransfer", dependencies: ["NotebookCore", "CSQLite"]),
    .testTarget(name: "NotebookCoreTests", dependencies: ["NotebookCore"]),
    .testTarget(name: "NotebookArchiveTransferTests", dependencies: ["NotebookArchiveTransfer"], resources: [.copy("Resources")]),
  ]
)
