import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

struct Corpus {
  let name: String
  let provenance: String
  let strokes: [[Point]]
  var count: Int { strokes.reduce(0) { $0 + $1.count } }
}
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
var sink: Double = 0
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
  precondition(value(), message); checks += 1
}
func point(_ i: Int, radius: Float) -> Point {
  .init(position: .init(Float(i) * 0.8, 20 * sin(Float(i) / 21)), radius: radius,
    premultipliedColor: .init(0.1, 0.2, 0.3, 1))
}
func normalize(_ points: [Point]) -> [Point] {
  var result: [Point] = []
  for point in points {
    if let last = result.last, InkStrokeGeometry.areCoincident(last, point) { result[result.count - 1] = point }
    else { result.append(point) }
  }
  return result
}
@inline(never) func mesh(_ points: [Point]) -> [Vertex] {
  var vertices: [Vertex] = []
  InkStrokeGeometry.appendStrokeVertices(renderPoints: points, to: &vertices)
  return vertices
}
@inline(never) func consume(_ value: [[Vertex]]) {
  // Read the entire result after the clock stops; prevents a count-only fake workload.
  for stroke in value { for vertex in stroke { sink += Double(vertex.position.x + vertex.position.y) } }
}
@inline(never) func consume(_ value: [[Point]]) {
  for stroke in value { for point in stroke { sink += Double(point.radius + point.position.x) } }
}
@inline(never) func consume(_ value: [PackedStroke]) {
  for stroke in value {
    sink += Double(stroke.bytes)
    for c in stroke.codes { sink += Double(c) }
    for r in stroke.radii { sink += Double(r) }
    for r in stroke.escapes { sink += Double(r) }
  }
}
func time<T>(_ work: () -> T, consume: (T) -> Void) -> Double {
  let start = DispatchTime.now().uptimeNanoseconds
  let result = work()
  let end = DispatchTime.now().uptimeNanoseconds
  consume(result)
  return Double(end - start) / 1e6
}
func stats(_ values: [Double]) -> [String: Any] {
  let sorted = values.sorted()
  return ["median_ms": (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2,
    "p95_ms": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1], "samples_ms": values]
}

// Contract checks exercise packing boundaries, absolute escapes, restarts,
// feedback error, and position/color preservation. No live workspace is read.
for bits in [4, 8, 12] {
  let levels = 1 << bits
  for code in 1..<levels {
    var factor: Float = 1
    for level in 0..<bits {
      let positive = (code & (1 << (bits - 1 - level))) != 0
      factor *= exp2((positive ? Float(1) : -1) / Float(1 << level))
    }
    check(abs(factor - PackedStroke.factors[bits]![code]) < 0.00001, "ordered-factor LUT")
  }
  check(PackedStroke.factors[bits]![1 << (bits - 1)] != PackedStroke.factors[bits]![1 << (bits - 2)],
    "same popcount must not erase scale order")
}
for length in [0, 1, 2, 3, 63, 64, 65, 127, 129] {
  let input = (0..<length).map { i in point(i, radius: i.isMultiple(of: 7) ? 16 : 0.25 + Float(i % 11) / 3) }
  for encoding in Encoding.allCases {
    let stored = PackedStroke(input, encoding: encoding), decoded = stored.decode()
    check(decoded.count == input.count, "sample count")
    for i in input.indices {
      check(decoded[i].position == input[i].position && decoded[i].premultipliedColor == input[i].premultipliedColor,
        "unchanged non-radius attributes")
      if encoding.relative {
        let bound = exp2(Float(2) / Float(1 << encoding.bits)) - 1 + 0.000002
        check(abs(decoded[i].radius / input[i].radius - 1) <= bound, "bounded feedback error")
        if i.isMultiple(of: PackedStroke.blockSize) { check(decoded[i].radius == input[i].radius, "exact restart") }
      } else if encoding.bits > 0 {
        let bound = (stored.upper - stored.lower) / Float(2 * ((1 << encoding.bits) - 1)) + 0.000002
        check(abs(decoded[i].radius - input[i].radius) <= bound, "absolute quantization bound")
      } else { check(decoded[i] == input[i], "lossless baseline") }
    }
  }
}
let sudden = PackedStroke([point(0, radius: 0.25), point(1, radius: 16)], encoding: .relative8)
check(sudden.escapes.count == 1 && sudden.decode()[1].radius == 16, "large jump must escape, not clip")

var rng: UInt64 = 0x54c8f24d7a
func random() -> Float {
  rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
  return Float(rng & 0xffffff) / Float(0xffffff)
}
var corpora: [Corpus] = []
for name in ["constant", "smooth", "abrupt", "noise"] {
  let strokes = (0..<96).map { stroke in
    (0..<256).map { i in
      let radius: Float
      switch name {
      case "constant": radius = 2
      case "smooth": radius = 0.25 + 3.75 * (0.5 + 0.5 * sin(Float(i) / 29 + Float(stroke) * 0.03))
      case "abrupt": radius = (i / 8).isMultiple(of: 2) ? 0.25 : 4
      default: radius = 0.25 + 3.75 * random()
      }
      return point(i, radius: radius)
    }
  }
  corpora.append(.init(name: name, provenance: "synthetic positions and synthetic radius; no measured Pencil pressure", strokes: strokes))
}
let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: [[[[Double]]]]]
var measured: [[Point]] = []
for name in fixture.keys.sorted() {
  for drawing in fixture[name]! {
    for stroke in drawing {
      measured.append(normalize(stroke.enumerated().map { i, xy in
        .init(position: .init(Float(xy[0]), Float(xy[1])),
          radius: 0.25 + 3.75 * (0.5 + 0.5 * sin(Float(i) / 29)),
          premultipliedColor: .init(0.1, 0.2, 0.3, 1))
      }))
    }
  }
}
corpora.append(.init(name: "measured-path", provenance: "QuickShapeMeasured.json coordinates; synthetic radius, NOT measured pressure", strokes: measured))
corpora.append(.init(name: "long-100k", provenance: "100,000 synthetic points in ONE stroke, not 100,000 scene objects",
  strokes: [(0..<100_000).map { point($0, radius: 0.25 + 3.75 * (0.5 + 0.5 * sin(Float($0) / 29))) }]))

struct Record {
  let corpus: Corpus
  let encoding: Encoding
  let packed: [PackedStroke]
  var metrics: [String: Any]
  var encode: [Double] = []
  var decode: [Double] = []
  var restoreMesh: [Double] = []
  var captureMesh: [Double] = []
}
var reports: [[String: Any]] = []
for corpus in corpora {
  let baseline = corpus.strokes.map(mesh)
  let vertexCount = baseline.reduce(0) { $0 + $1.count }
  var records: [Record] = []
  for encoding in Encoding.allCases {
    let packed = corpus.strokes.map { PackedStroke($0, encoding: encoding) }
    let decoded = packed.map { $0.decode() }
    let vertices = decoded.map(mesh)
    var squared: Double = 0, maxRadius: Float = 0, maxRelative: Float = 0, maxVertex: Float = 0
    for s in corpus.strokes.indices {
      check(vertices[s].count == baseline[s].count, "identical triangle topology")
      for i in corpus.strokes[s].indices {
        let original = corpus.strokes[s][i], result = decoded[s][i]
        let error = abs(original.radius - result.radius)
        squared += Double(error * error); maxRadius = max(maxRadius, error)
        maxRelative = max(maxRelative, error / original.radius)
        check(result.position == original.position && result.premultipliedColor == original.premultipliedColor,
          "geometry/color preserved")
      }
      for i in vertices[s].indices {
        let d = vertices[s][i].position - baseline[s][i].position
        maxVertex = max(maxVertex, sqrt(d.x * d.x + d.y * d.y))
      }
    }
    if encoding.relative {
      check(maxRelative <= exp2(Float(2) / Float(1 << encoding.bits)) - 1 + 0.000003, "corpus feedback error bound")
    }
    let payload = packed.reduce(0) { $0 + $1.bytes }
    let lookup = encoding.relative ? (1 << encoding.bits) * 4 : 0
    records.append(.init(corpus: corpus, encoding: encoding, packed: packed, metrics: [
      "encoding": encoding.rawValue, "sample_payload_bytes": payload,
      "radius_payload_bytes": packed.reduce(0) { $0 + $1.radiusBytes },
      "shared_lookup_bytes": lookup, "payload_plus_lookup_bytes": payload + lookup,
      "mesh_bytes": vertexCount * MemoryLayout<Vertex>.stride,
      "escape_count": packed.reduce(0) { $0 + $1.escapes.count },
      "radius_rmse_points": sqrt(squared / Double(corpus.count)), "radius_max_error_points": maxRadius,
      "radius_max_relative_error": maxRelative, "vertex_max_error_points": maxVertex,
      "contour_within_0_1pt": maxVertex <= 0.1]))
  }
  // Rotate starting encoding every round to reduce warmup/thermal order bias.
  // The input, packed representation and baseline meshes already exist: warm CPU microbenchmark.
  for round in 0..<12 {
    for step in records.indices {
      let i = (step + round) % records.count, encoding = records[i].encoding
      let packed = records[i].packed
      let e = time({ corpus.strokes.map { PackedStroke($0, encoding: encoding) } }, consume: consume)
      let d = time({ packed.map { $0.decode() } }, consume: consume)
      let r = time({ packed.map { mesh($0.decode()) } }, consume: consume)
      let c = time({ corpus.strokes.map { mesh(PackedStroke($0, encoding: encoding).decode()) } }, consume: consume)
      if round >= 2 {
        records[i].encode.append(e); records[i].decode.append(d)
        records[i].restoreMesh.append(r); records[i].captureMesh.append(c)
      }
    }
  }
  var rows: [[String: Any]] = []
  for var record in records {
    record.metrics["encode"] = stats(record.encode)
    record.metrics["decode"] = stats(record.decode)
    record.metrics["restore_and_mesh"] = stats(record.restoreMesh)
    record.metrics["encode_decode_and_mesh"] = stats(record.captureMesh)
    rows.append(record.metrics)
    let ms = stats(record.restoreMesh)["median_ms"] as! Double
    print(String(format: "%@ %@ bytes=%d restore_mesh_ms=%.3f contour_error=%.5f",
      corpus.name, record.encoding.rawValue, record.metrics["payload_plus_lookup_bytes"] as! Int,
      ms, record.metrics["vertex_max_error_points"] as! Float))
  }
  reports.append(["name": corpus.name, "provenance": corpus.provenance, "points": corpus.count,
    "strokes": corpus.strokes.count, "vertices": vertexCount, "variants": rows])
}

// Render actual triangles from the production tessellator; same transform for
// every method in each row. This is contour inspection, not Metal frame timing.
let width = 1600, height = 930
let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 17) {
  let attributes: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil),
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.15, alpha: 1)]
  let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
  context.textPosition = .init(x: x, y: y); CTLineDraw(line, context)
}
label("Production stroke geometry / identical coordinates / synthetic pressure", x: 30, y: 890, size: 23)
let show: [Encoding] = [.current, .absolute8, .relative8, .relative12]
for (col, encoding) in show.enumerated() { label(encoding.rawValue, x: CGFloat(30 + col * 395), y: 844, size: 20) }
for (row, name) in ["constant", "smooth", "abrupt", "noise"].enumerated() {
  let source = Array(corpora.first { $0.name == name }!.strokes[0].prefix(170))
  let baselineY = CGFloat(720 - row * 195)
  for (col, encoding) in show.enumerated() {
    let vertices = mesh(PackedStroke(source, encoding: encoding).decode())
    context.saveGState()
    context.translateBy(x: CGFloat(30 + col * 395), y: baselineY)
    context.scaleBy(x: 2.6, y: 2.6)
    context.setFillColor(CGColor(red: 0.08, green: 0.18, blue: 0.30, alpha: 1))
    context.beginPath()
    for i in stride(from: 0, to: vertices.count, by: 3) {
      context.move(to: .init(x: CGFloat(vertices[i].position.x), y: CGFloat(vertices[i].position.y)))
      context.addLine(to: .init(x: CGFloat(vertices[i+1].position.x), y: CGFloat(vertices[i+1].position.y)))
      context.addLine(to: .init(x: CGFloat(vertices[i+2].position.x), y: CGFloat(vertices[i+2].position.y)))
      context.closePath()
    }
    context.fillPath(); context.restoreGState()
    label(name, x: CGFloat(30 + col * 395), y: baselineY + 78)
  }
}
let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent("contours.png") as CFURL,
  UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
check(CGImageDestinationFinalize(destination), "PNG export")
let result: [String: Any] = ["schema": 1, "date": ISO8601DateFormatter().string(from: Date()),
  "scope": "CPU macOS -O; normalized render samples and production InkStrokeGeometry, NOT live incremental Pencil/Metal/iPad",
  "rounds": 10, "warmup_rounds": 2, "checks_passed": checks, "checksum": sink,
  "memory_scope": "used array payload plus one lookup per relative encoding; excludes capacity, object overhead, RSS, source metadata, caches, GPU allocations",
  "quality_gate": "maximum corresponding triangle vertex displacement <= 0.1 document point; not visual equivalence at arbitrary zoom",
  "corpora": reports]
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"))
print("PASS \(checks) checks; checksum=\(sink)")
