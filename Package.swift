// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "Tetrad",
  platforms: [
    .iOS(.v27),
    .macOS(.v27),
  ],
  products: [
    .library(name: "TetradCore", targets: ["TetradCore"]),
  ],
  targets: [
    .target(name: "TetradCore"),
    .testTarget(name: "TetradCoreTests", dependencies: ["TetradCore"]),
  ]
)
