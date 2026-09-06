import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// A fixture is an import workload, not an alternative Notebook store. Every
// original is generated independently; the manifest is published only at end.
struct GeneratorError: Error, CustomStringConvertible {
  let description: String
  init(_ message: String) { description = message }
}
struct Random {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9e3779b97f4a7c15
    var z = state
    z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
    z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
    return z ^ (z >> 31)
  }
  mutating func integer(_ count: Int) -> Int { Int(next() % UInt64(count)) }
}
struct Source: Codable {
  let path: String
  let sha256: String
  let bytes: Int
  let format: String
  let pages: Int?
  let orientation: Int?
  let uniformType: String?
  let pixelWidth: Int?
  let pixelHeight: Int?
  let complexity: Complexity
}
struct Complexity: Codable {
  var vectorSegments = 0
  var inkSamples = 0
  var textBytes = 0
  var documentBlocks = 0
  var interactiveControls = 0
  mutating func add(_ other: Self) {
    vectorSegments += other.vectorSegments; inkSamples += other.inkSamples
    textBytes += other.textBytes; documentBlocks += other.documentBlocks
    interactiveControls += other.interactiveControls
  }
}
struct Point: Codable { let x: Double; let y: Double }
struct InkSample: Codable {
  let x: Double
  let y: Double
  let width: Double
  let force: Double
  let timeOffset: Double
}
struct InkStroke: Codable {
  let id: String
  let tool: String
  let samples: [InkSample]
}
struct InkPage: Codable {
  let id: String
  let width: Double
  let height: Double
  let strokes: [InkStroke]
}
struct Recipe: Codable {
  let ordinal: Int
  let itemID: String
  let kind: String
  let source: Source
  let sparse: Point
  let dense: Point
  let overlap: Point
  let portalDepth: Int
}
struct Manifest: Codable {
  let format: Int
  let seed: UInt64
  let itemCount: Int
  let uniqueSources: Int
  let totalBytes: UInt64
  let knownPageCount: Int
  let unpaginatedDocuments: Int
  let totalPixels: UInt64
  let complexity: Complexity
  let countsByKind: [String: Int]
  let recordsSHA256: String
  let generatorSHA256: String
  let encoderPlatform: String
  let scope: String
}
let encoder: JSONEncoder = {
  let value = JSONEncoder()
  value.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return value
}()
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func identity(_ seed: UInt64, _ number: Int) -> String {
  var bytes = Array(SHA256.hash(data: Data("notebook-load-1:\(seed):\(number)".utf8)).prefix(16))
  bytes[6] = (bytes[6] & 15) | 0x40; bytes[8] = (bytes[8] & 63) | 0x80
  let hex = bytes.map { String(format: "%02x", $0) }.joined()
  let starts = [0, 8, 12, 16, 20], lengths = [8, 4, 4, 4, 12]
  return zip(starts, lengths).map { String(hex.dropFirst($0).prefix($1)) }.joined(separator: "-")
}
func number(_ value: Double) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value) }

func svg(number index: Int, random: inout Random, count: Int) -> Data {
  var points = ""
  for x in 0..<count {
    let y = 70 + random.integer(820)
    points += "\(x == 0 ? "M" : "L")\(number(Double(x) * 1400 / Double(max(1, count - 1)))) \(y) "
  }
  let color = String(format: "%06x", random.integer(0xffffff))
  let source = """
  <svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1000" viewBox="0 0 1600 1000">
  <rect width="1600" height="1000" fill="#fbfaf5"/>
  <g stroke="#88908f" stroke-width="0.5"><path d="M80 80 V900 H1520"/></g>
  <text x="80" y="48" font-family="sans-serif" font-size="26">Notebook workload \(index)</text>
  <path transform="translate(80 0)" d="\(points)" fill="none" stroke="#\(color)" stroke-width="1"/>
  </svg>
  """
  return Data(source.utf8)
}

/// Deterministic PDF objects keep CropBox, rotation and mixed physical sizes.
/// The test workload does not depend on a PDF metadata clock or an external tool.
func pdf(number index: Int, random: inout Random, pages: Int, samples: Int) -> Data {
  var objects = [String](repeating: "", count: 3 + pages * 2)
  objects[0] = "<< /Type /Catalog /Pages 2 0 R >>"
  let children = (0..<pages).map { "\(4 + $0 * 2) 0 R" }.joined(separator: " ")
  objects[1] = "<< /Type /Pages /Kids [\(children)] /Count \(pages) >>"
  objects[2] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
  for page in 0..<pages {
    let sizes: [(Int, Int)] = [(595, 842), (612, 792), (1191, 842), (420, 595)]
    let (width, height) = sizes[(index + page) % sizes.count]
    let rotation = [0, 90, 180, 270][(index + page) % 4]
    var stream = "BT /F1 12 Tf 36 \(height - 48) Td (Notebook \(index), actual page \(page + 1)) Tj ET\n0.15 0.35 0.65 RG 0.4 w\n"
    for sample in 0..<samples {
      let x = 36 + Double(sample) * Double(width - 72) / Double(max(1, samples - 1))
      let y = 36 + random.integer(height - 110)
      stream += "\(number(x)) \(y) \(sample == 0 ? "m" : "l")\n"
    }
    stream += "S\n"
    for row in 0..<16 {
      stream += "BT /F1 8 Tf 40 \(height - 75 - row * 13) Td (Sample \(row): \(random.next())) Tj ET\n"
    }
    let pageObject = 3 + page * 2, contentObject = pageObject + 1
    objects[pageObject] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) \(height)] /CropBox [12 18 \(width - 12) \(height - 18)] /Rotate \(rotation) /Resources << /Font << /F1 3 0 R >> >> /Contents \(contentObject + 1) 0 R >>"
    objects[contentObject] = "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream"
  }
  var data = Data("%PDF-1.7\n%Notebook fixture\n".utf8)
  var offsets: [Int] = []
  for (position, object) in objects.enumerated() {
    offsets.append(data.count)
    data.append(Data("\(position + 1) 0 obj\n\(object)\nendobj\n".utf8))
  }
  let xref = data.count
  data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
  for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
  data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
  return data
}

func image(number index: Int, random: inout Random, width: Int, height: Int, type: UTType) throws -> Data {
  let count = width * height * 4
  var pixels = [UInt8](repeating: 255, count: count)
  for y in 0..<height {
    for x in 0..<width {
      let offset = (y * width + x) * 4
      let noise = random.next()
      pixels[offset] = UInt8(truncatingIfNeeded: noise ^ UInt64(x * 3))
      pixels[offset + 1] = UInt8(truncatingIfNeeded: (noise >> 16) ^ UInt64(y * 7))
      pixels[offset + 2] = UInt8(truncatingIfNeeded: (noise >> 32) ^ UInt64(index * 11))
    }
  }
  guard let provider = CGDataProvider(data: Data(pixels) as CFData),
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  else { throw GeneratorError("Cannot prepare fixture image") }
  let output = NSMutableData()
  guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
    throw GeneratorError("ImageIO cannot encode \(type.identifier)")
  }
  let properties: [CFString: Any] = [
    kCGImageDestinationLossyCompressionQuality: 0.82,
    kCGImagePropertyOrientation: [1, 3, 6, 8][(index / 8) % 4],
    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: [1, 3, 6, 8][(index / 8) % 4]],
  ]
  CGImageDestinationAddImage(destination, image, properties as CFDictionary)
  guard CGImageDestinationFinalize(destination) else { throw GeneratorError("Image encoding failed") }
  return output as Data
}

func text(number index: Int, random: inout Random, paragraphs: Int, interactive: Bool) -> Data {
  var text = "# Workload \(index)\n\n"
  for paragraph in 0..<paragraphs {
    text += "## Relation \(paragraph + 1)\n\n"
    for sample in 0..<12 {
      text += "Point \(sample) carries \(random.next()) observations; the next relation preserves the previous source. "
    }
    text += "\n\n$$f_{\(paragraph)}(x)=\\sum_{k=1}^{\(random.integer(90) + 10)}\\frac{x^k}{k!}$$\n\n"
  }
  if interactive {
    text = """
    <!doctype html><meta charset="utf-8"><style>body{font:18px system-ui;background:#fbfaf5}svg{width:100%;height:300px}</style>
    <h1>Model \(index)</h1><label>Input <input id="input" type="range" min="0" max="100" value="\(index % 100)"></label>
    <output id="output"></output><svg viewBox="0 0 1000 300"><path id="curve" fill="none" stroke="navy" stroke-width=".5"/></svg>
    <script>const initial=\(random.integer(10000));let value=window.notebook?.state?.value??initial%100;
    function render(){output.textContent=String(value*value);curve.setAttribute('d',Array.from({length:1024},(_,i)=>`${i?'L':'M'}${i} ${150+Math.sin(i*.01+value)*110}`).join(' '));input.value=value}
    input.oninput=()=>{value=Number(input.value);window.notebook?.commit({value});render()};render();</script>
    <details><summary>Source</summary><pre>\(text)</pre></details>
    """
  }
  return Data(text.utf8)
}

func run() throws {
  let arguments = CommandLine.arguments
  guard arguments.count == 5, let count = Int(arguments[2]), (1...100_000).contains(count),
    let seed = UInt64(arguments[3]), arguments[4].count == 64,
    arguments[4].allSatisfy({ "0123456789abcdef".contains($0) }) else {
    throw GeneratorError("Usage: generator <NEW output directory> <1...100000 count> <seed> <generator source sha256>")
  }
  let output = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
  let fm = FileManager.default
  guard !fm.fileExists(atPath: output.path) else { throw GeneratorError("Output already exists; no existing data is replaced") }
  let stage = output.deletingLastPathComponent().appendingPathComponent(".\(output.lastPathComponent).preparing-\(UUID().uuidString)")
  try fm.createDirectory(at: stage.appendingPathComponent("originals"), withIntermediateDirectories: true)
  var completed = false
  defer { if !completed { try? fm.removeItem(at: stage) } }
  let records = stage.appendingPathComponent("items.jsonl")
  fm.createFile(atPath: records.path, contents: nil)
  let handle = try FileHandle(forWritingTo: records)
  defer { try? handle.close() }
  var totalBytes: UInt64 = 0, totalPixels: UInt64 = 0
  var totalComplexity = Complexity()
  var totalPages = 0
  var hashes: Set<String> = [], counts: [String: Int] = [:]
  var recordDigest = SHA256()
  for index in 0..<count {
    try autoreleasepool {
      var random = Random(state: seed ^ (UInt64(index) &* 0xd6e8feb86659fd93))
      let kind: String, format: String, bytes: Data, pages: Int?
      var measured = Complexity()
      var pixelWidth: Int?, pixelHeight: Int?, orientation: Int?
      var uniformType: String?
      let complexity = index % 97 == 0 ? 8192 : (512 + random.integer(1024))
      switch index % 8 {
      case 0:
        kind = "notebook"; format = "ink.json"; pages = 4
        let contactsPerPage = max(4, complexity / 4 / 24)
        measured.inkSamples = contactsPerPage * 24 * 4
        let leaves = (0..<4).map { page in
          let strokes = (0..<contactsPerPage).map { stroke in
            let x = Double(40 + random.integer(570)), y = Double(50 + random.integer(1000))
            let amplitude = Double(10 + random.integer(30)), phase = Double(random.integer(100)) / 10
            return InkStroke(id: identity(seed ^ UInt64(index), page * contactsPerPage + stroke),
              tool: stroke % 11 == 10 ? "eraser" : "pen", samples: (0..<24).map { sample in
                let force = 0.3 + Double(random.integer(600)) / 1000
                return InkSample(x: x + Double(sample) * 6,
                  y: y + sin(Double(sample) / 3 + phase) * amplitude,
                  width: stroke % 11 == 10 ? 18 : 1.5 + force * 3,
                  force: force, timeOffset: Double(sample) / 120)
              })
          }
          return InkPage(id: identity(seed ^ UInt64(index) ^ 0x50414745, page), width: 834, height: 1194,
            strokes: strokes)
        }
        bytes = try encoder.encode(leaves)
      case 1:
        kind = "document"; format = "md"; pages = nil
        let paragraphs = index % 97 == 0 ? 300 : 24
        measured.documentBlocks = 1 + paragraphs * 3
        bytes = text(number: index, random: &random, paragraphs: paragraphs, interactive: false)
        measured.textBytes = bytes.count
      case 2:
        kind = "svg"; format = "svg"; pages = 1; measured.vectorSegments = complexity - 1 + 2
        bytes = svg(number: index, random: &random, count: complexity)
      case 3:
        kind = "interactive"; format = "html"; pages = 1; measured.vectorSegments = 1023
        measured.interactiveControls = 1
        bytes = text(number: index, random: &random, paragraphs: 4, interactive: true)
      case 4:
        kind = "pdf"; format = "pdf"
        let count = 2 + random.integer(7); pages = count
        measured.vectorSegments = (complexity - 1) * count
        bytes = pdf(number: index, random: &random, pages: count, samples: complexity)
        guard let provider = CGDataProvider(data: bytes as CFData), let document = CGPDFDocument(provider),
          document.numberOfPages == count, !document.isEncrypted else { throw GeneratorError("Generated PDF is not readable") }
      default:
        kind = "image"; pages = 1
        let type: UTType = index % 8 == 5 ? .jpeg : (index % 8 == 6 ? .png : .heic)
        format = type == .jpeg ? "jpeg" : (type == .png ? "png" : (index % 16 == 7 ? "heic" : "heif"))
        let width = index % 97 == 0 ? 4096 : 512
        let height = index % 97 == 0 ? 3072 : 384
        pixelWidth = width; pixelHeight = height
        orientation = [1, 3, 6, 8][(index / 8) % 4]
        bytes = try image(number: index, random: &random, width: width, height: height, type: type)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) == 1,
          CGImageSourceGetStatus(source) == .statusComplete else { throw GeneratorError("Generated image is not readable") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard properties?[kCGImagePropertyPixelWidth] as? Int == width,
          properties?[kCGImagePropertyPixelHeight] as? Int == height,
          (properties?[kCGImagePropertyOrientation] as? Int ?? 1) == orientation else {
          throw GeneratorError("Image \(index) metadata differs: \(String(describing: properties)); expected \(width)x\(height) orientation \(String(describing: orientation))")
        }
        uniformType = CGImageSourceGetType(source) as String?
      }
      let hash = digest(bytes)
      guard hashes.insert(hash).inserted else { throw GeneratorError("A duplicate original would invalidate this workload") }
      let path = "originals/\(identity(seed, index)).\(format)"
      try bytes.write(to: stage.appendingPathComponent(path), options: .atomic)
      let visible = index < 24
      let recipe = Recipe(ordinal: index, itemID: identity(seed, index), kind: kind,
        source: .init(path: path, sha256: hash, bytes: bytes.count, format: format,
          pages: pages, orientation: orientation, uniformType: uniformType, pixelWidth: pixelWidth, pixelHeight: pixelHeight, complexity: measured),
        sparse: .init(x: visible ? Double(index % 6) * 1500 : 100_000 + Double(index % 317) * 1800,
          y: visible ? Double(index / 6) * 1800 : 100_000 + Double(index / 317) * 2100),
        dense: .init(x: Double(index % 317) * 24, y: Double(index / 317) * 28),
        overlap: .init(x: 0, y: 0), portalDepth: index % 9)
      var encoded = try encoder.encode(recipe); encoded.append(10)
      try handle.write(contentsOf: encoded); recordDigest.update(data: encoded)
      totalBytes += UInt64(bytes.count); totalPages += pages ?? 0
      totalPixels += UInt64(pixelWidth ?? 0) * UInt64(pixelHeight ?? 0)
      totalComplexity.add(measured); counts[kind, default: 0] += 1
      if (index + 1) % 1000 == 0 { print("prepared \(index + 1)/\(count), \(totalBytes) original bytes") }
    }
  }
  try handle.synchronize()
  let manifest = Manifest(format: 1, seed: seed, itemCount: count, uniqueSources: hashes.count,
    totalBytes: totalBytes, knownPageCount: totalPages, unpaginatedDocuments: counts["document", default: 0], totalPixels: totalPixels, complexity: totalComplexity,
    countsByKind: counts, recordsSHA256: recordDigest.finalize().map { String(format: "%02x", $0) }.joined(),
    generatorSHA256: arguments[4], encoderPlatform: ProcessInfo.processInfo.operatingSystemVersionString,
    scope: "Unique import workload, not an installed Notebook archive or physical frame-time proof. Notebook samples are import recipes, not canonical PageInkDrawing; Markdown page count is absent until native pagination. Complexity counts describe actual generated source, not measured execution cost.")
  try encoder.encode(manifest).write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
  try fm.moveItem(at: stage, to: output)
  completed = true
  print(String(data: try encoder.encode(manifest), encoding: .utf8)!)
}
do { try run() } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
