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
    .executable(name: "notebook-bridge", targets: ["NotebookBridge"]),
    .executable(name: "notebook-ipc-test-host", targets: ["NotebookIPCTestHost"]),
  ],
  targets: [
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
    .target(name: "NotebookCore", dependencies: ["CSQLite"]),
    .executableTarget(name: "NotebookBridge", dependencies: ["NotebookCore"]),
    .executableTarget(name: "NotebookIPCTestHost", dependencies: ["NotebookCore"], path: "Tests/NotebookIPCTestHost"),
    .testTarget(name: "NotebookCoreTests", dependencies: ["NotebookCore"]),
  ]
)
