import Foundation
import Metal

let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
let gpu = try CompactInkTestRenderer(library: library)
let color = SIMD4<Float>(0.1, 0.35, 0.7, 1)
func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
var results: [[String: Any]] = []
for count in [10_000, 100_000, 1_000_000] {
  let strokes = stride(from: 0, to: count, by: 250).map { start in
    (0..<min(250, count - start)).map { i in
      let stroke = start / 250
      let t = Float(i) / 249
      let p = SIMD2<Float>(
        10 + Float(stroke % 40) * 25 + 24 * t, 10 + Float(stroke / 40 % 60) * 12 + 2 * sin(t * 5))
      return InkStrokeGeometry.RenderPoint(position: p, radius: 0.4, premultipliedColor: color)
    }
  }
  var modes: [(String, [CompactInkTestRenderer.Draw], Double)] = []
  for (mode, compact, lod) in [
    ("cpu-triangles", false, false), ("compact-exact", true, false), ("compact-lod", true, true),
  ] {
    let start = ProcessInfo.processInfo.systemUptime
    let draws = strokes.flatMap {
      gpu.prepare($0, color: color, compact: compact, lodScale: lod ? 1 : nil)
    }
    modes.append((mode, draws, (ProcessInfo.processInfo.systemUptime - start) * 1000))
  }
  _ = try gpu.run(modes[0].1)
  let canonical = gpu.pixels()
  for (mode, draws, _) in modes.dropFirst() {
    _ = try gpu.run(draws)
    let pixels = gpu.pixels()
    let rmse =
      sqrt(
        zip(canonical, pixels).reduce(0.0) { $0 + pow(Double($1.0) - Double($1.1), 2) }
          / Double(pixels.count)) / 255
    print("QUALITY \(count) \(mode) rmse=\(rmse)")
    precondition(rmse < (mode == "compact-exact" ? 0.001 : 0.025), "Rendered quality regression")
  }
  var timings: [String: [(Double, Double)]] = [:]
  for round in 0..<24 {
    for index in 0..<modes.count {
      let (mode, draws, _) = modes[(index + round) % modes.count]
      let result = try gpu.run(draws, affine: .init(.init(1, 1, Float(round % 3) * 0.3, 0)))
      if round >= 4 { timings[mode, default: []].append((result.gpu, result.wall)) }
    }
  }
  for (mode, draws, preparation) in modes {
    let times = timings[mode]!
    let row: [String: Any] = [
      "source_nodes": count, "mode": mode, "gpu_ms": median(times.map(\.0)),
      "wall_ms": median(times.map(\.1)), "preparation_ms": preparation,
      "upload_bytes": draws.reduce(0) { $0 + $1.buffer.length },
      "draw_calls": draws.count, "gpu_samples_ms": times.map(\.0),
      "wall_samples_ms": times.map(\.1),
    ]
    results.append(row)
    print(row.filter { !$0.key.contains("samples") })
  }
}
try JSONSerialization.data(
  withJSONObject: ["device": device.name, "results": results],
  options: [.prettyPrinted, .sortedKeys]
)
.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
