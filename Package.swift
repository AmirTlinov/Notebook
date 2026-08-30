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
  ],
  targets: [
    .target(name: "NotebookCore"),
    .testTarget(name: "NotebookCoreTests", dependencies: ["NotebookCore"]),
  ]
)
