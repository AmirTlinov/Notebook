import Foundation
import Metal
import NotebookCore
import XCTest

@testable import Notebook

final class CompactInkRenderingTests: XCTestCase {
  func testGPUContourPressureCapsEraserAndAffineMatchCanonicalPixels() throws {
    let gpu = try CompactInkTestRenderer()
    let color = SIMD4<Float>(0.1, 0.35, 0.7, 1)
    let paths: [[SIMD2<Float>]] = [
      [.init(120, 80)], [.init(100, 150), .init(260, 150)],
      [.init(400, 100), .init(460, 100), .init(400, 100), .init(400, 210)],
      (0..<800).map { .init(40 + Float($0), 400 + 30 * sin(Float($0) / 40)) },
    ]
    var reference: [CompactInkTestRenderer.Draw] = []
    var actual: [CompactInkTestRenderer.Draw] = []
    for (index, path) in paths.enumerated() {
      let points = path.enumerated().map { i, p in
        let alpha: Float = 0.2 + 0.8 * Float(i + 1) / Float(path.count)
        return InkStrokeGeometry.RenderPoint(
          position: p, radius: 3 + Float(i % 11) / 4,
          premultipliedColor: .init(color.x * alpha, color.y * alpha, color.z * alpha, alpha))
      }
      for compact in [false, true] {
        let draw = gpu.prepare(points, color: color, compact: compact)
        if compact { actual += draw } else { reference += draw }
      }
      if index == 3 {
        let eraser = [SIMD2<Float>(350, 300), .init(350, 460), .init(410, 400)].map {
          InkStrokeGeometry.RenderPoint(
            position: $0, radius: 12, premultipliedColor: .init(repeating: 1))
        }
        reference += gpu.prepare(eraser, color: .init(repeating: 1), eraser: true, compact: false)
        actual += gpu.prepare(eraser, color: .init(repeating: 1), eraser: true, compact: true)
      }
    }
    for affine in [InkAffine(), InkAffine(x: .init(0.8, 0.25, 15, 0), y: .init(-0.1, 1.1, 60, 0))] {
      _ = try gpu.run(reference, affine: affine)
      let before = gpu.pixels()
      _ = try gpu.run(actual, affine: affine)
      let after = gpu.pixels()
      let rmse =
        sqrt(
          zip(before, after).reduce(0.0) { $0 + pow(Double($1.0) - Double($1.1), 2) }
            / Double(before.count)) / 255
      XCTAssertLessThan(
        rmse, 0.001, "Actual Metal contour and painter order must match, including shear")
    }
    XCTAssertEqual(MemoryLayout<InkRenderGeometry.Node>.stride, 24)
    XCTAssertEqual(MemoryLayout<InkPrimitive>.stride, 32)
    XCTAssertEqual(MemoryLayout<InkAffine>.stride, 32)
    XCTAssertGreaterThan(InkAffine(x: .init(1, 1, 0, 0), y: .init(0, 1, 0, 0)).maximumStretch, 1.61)
  }

  func testMeasureOneHundredThousandNodesOnActualDevice() throws {
    let gpu = try CompactInkTestRenderer()
    let color = SIMD4<Float>(0.1, 0.35, 0.7, 1)
    let strokes: [[InkStrokeGeometry.RenderPoint]] = (0..<400).map { stroke in
      (0..<250).map { i in
        let t = Float(i) / 249
        return .init(
          position: .init(
            10 + Float(stroke % 40) * 25 + 24 * t, 10 + Float(stroke / 40) * 12 + 2 * sin(t * 5)),
          radius: 0.4, premultipliedColor: color)
      }
    }
    let names = ["cpu-triangles", "compact-exact", "compact-lod-request"]
    let modes = names.enumerated().map { index, _ in
      strokes.flatMap {
        gpu.prepare($0, color: color, compact: index > 0, lodScale: index == 2 ? 1 : nil)
      }
    }
    var gpuTimes = [[Double]](repeating: [], count: 3)
    var wallTimes = gpuTimes
    for round in 0..<18 {
      for offset in 0..<3 {
        let mode = (round + offset) % 3
        let result = try gpu.run(modes[mode])
        if round >= 3 {
          gpuTimes[mode].append(result.gpu)
          wallTimes[mode].append(result.wall)
        }
      }
    }
    let result = names.enumerated().map { index, name -> [String: Any] in
      [
        "mode": name, "sourceNodes": 100000, "gpuMedianMS": gpuTimes[index].sorted()[7],
        "submitWaitMedianMS": wallTimes[index].sorted()[7],
        "payloadBytes": modes[index].reduce(0) { $0 + $1.buffer.length },
        "gpuSamplesMS": gpuTimes[index], "submitWaitSamplesMS": wallTimes[index],
      ]
    }
    let bytes = try JSONSerialization.data(
      withJSONObject: ["device": gpu.device.name, "results": result],
      options: [.prettyPrinted, .sortedKeys])
    let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
    attachment.name = "compact-ink-100k-device-measurement"
    attachment.lifetime = .keepAlways
    add(attachment)
    print("COMPACT_INK_DEVICE_MEASUREMENT " + String(decoding: bytes, as: UTF8.self))
    XCTAssertEqual(modes[1].reduce(0) { $0 + $1.buffer.length }, 2_400_000)
    // These authored 0.8-pixel strokes cannot take a geometric-only LOD:
    // retain coverage rather than accepting a smaller but different image.
    XCTAssertEqual(modes[2].reduce(0) { $0 + $1.buffer.length }, 2_400_000)
    _ = try gpu.run(modes[1]);let exact=gpu.pixels()
    _ = try gpu.run(modes[2]);XCTAssertEqual(gpu.pixels(),exact)
    XCTAssertTrue(exact.contains { $0 > 0 })
  }

  func testDistantLODIsBoundedAndZoomRestoresOriginalGPUData() throws {
    let gpu = try CompactInkTestRenderer()
    let color = SIMD4<Float>(0, 0, 0, 1)
    let points = (0..<2000).map { i in
      InkStrokeGeometry.RenderPoint(
        position: .init(Float(i), 500 + 0.2 * sin(Float(i) / 40)),
        radius: 4, premultipliedColor: color)
    }
    let full = gpu.prepare(points, color: color, compact: true)
    let distant = gpu.prepare(points, color: color, compact: true, lodScale: 0.4)
    XCTAssertLessThan(distant.reduce(0) { $0 + $1.count }, points.count / 10)
    let transform = InkAffine(.init(0.4, 0.4, 20, 20))
    _ = try gpu.run(full, affine: transform)
    let before = gpu.pixels()
    _ = try gpu.run(distant, affine: transform)
    let after = gpu.pixels()
    let changed = zip(before, after).filter { abs(Int($0) - Int($1)) > 2 }.count
    XCTAssertLessThan(changed, 1024 * 768 / 1000, "LOD error is in screen pixels, not source units")
    let zoomed = gpu.prepare(points, color: color, compact: true, lodScale: 100)
    XCTAssertEqual(zoomed.reduce(0) { $0 + $1.count }, full.reduce(0) { $0 + $1.count })
  }
}
