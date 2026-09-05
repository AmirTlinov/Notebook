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
  ],
  targets: [
    .target(name: "NotebookCore"),
    .executableTarget(name: "NotebookBridge", dependencies: ["NotebookCore"]),
    .testTarget(name: "NotebookCoreTests", dependencies: ["NotebookCore"]),
  ]
)
