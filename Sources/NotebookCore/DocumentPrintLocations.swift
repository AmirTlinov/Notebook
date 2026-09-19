import Foundation

/// Derived SyncTeX addresses for the exact compiled source. Coordinates are
/// physical PDF points, top-left origin; they never contain a scene camera.
public struct DocumentPrintLocation: Codable, Equatable, Sendable {
  public let blockID: String
  public let generatedLine: Int
  public let pageIndex: Int
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double
}

public enum DocumentPrintLocations {
  public static func decode(_ text: String, ranges: [DocumentPrintSourceRange]) throws -> [DocumentPrintLocation] {
    guard text.utf8.count <= 16*1024*1024, text.hasPrefix("SyncTeX Version:1\n") else { throw invalid() }
    var page = -1, unit = 1.0, magnification = 1000.0, xOffset = 0.0, yOffset = 0.0
    var result: [DocumentPrintLocation] = []
    struct LineBox {
      let x: Double, y: Double, width: Double, height: Double
      var lines: Set<Int> = []
    }
    var boxes: [LineBox?] = []
    func block(_ line: Int) -> String? {
      var low = 0, high = ranges.count
      while low < high { let m = low + (high-low)/2; if ranges[m].lastLine < line { low = m+1 } else { high = m } }
      return low < ranges.count && ranges[low].firstLine <= line ? ranges[low].blockID : nil
    }
    for (ordinal, record) in text.split(separator: "\n").enumerated() {
      if ordinal % 1024 == 0 { try Task.checkCancellation() }
      if record.hasPrefix("Unit:") { unit = Double(record.dropFirst(5)) ?? 0; continue }
      if record.hasPrefix("Magnification:") { magnification = Double(record.dropFirst(14)) ?? 0; continue }
      if record.hasPrefix("X Offset:") { xOffset = Double(record.dropFirst(9)) ?? .nan; continue }
      if record.hasPrefix("Y Offset:") { yOffset = Double(record.dropFirst(9)) ?? .nan; continue }
      if record.first == "{" { page = (Int(record.dropFirst()) ?? 0)-1; boxes.removeAll(keepingCapacity: true); guard (0..<4096).contains(page) else { throw invalid() }; continue }
      if record.first == ")" { if !boxes.isEmpty { boxes.removeLast() }; continue }
      // TeX often stamps the enclosing line with the following \par or blank
      // line. Glyph records carry the actual source line but have no extent;
      // inherit the nearest nonempty horizontal box, not an invented glyph size.
      if record.first == "g", page >= 0, let index = boxes.lastIndex(where: { $0 != nil }) {
        let address = record.dropFirst().prefix { $0 != ":" }.split(separator: ",")
        if address.count >= 2, address[0] == "1", let line = Int(address[1]), let id = block(line),
          var box = boxes[index], box.lines.insert(line).inserted {
          guard result.count < 524_288 else { throw invalid() }
          result.append(.init(blockID: id, generatedLine: line, pageIndex: page,
            x: box.x, y: box.y, width: box.width, height: box.height))
          boxes[index] = box
        }
        continue
      }
      // Vertical page envelopes carry the final line of the page; treating
      // them as text would falsely assign its entire paper to the last block.
      guard page >= 0, let kind = record.first, ["(", "h", "v", "r"].contains(kind) else { continue }
      let fields = record.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
      guard fields.count >= 3 else { continue }
      let address = fields[0].split(separator: ","), position = fields[1].split(separator: ","), size = fields[2].split(separator: ",")
      guard address.count >= 2, let line = Int(address[1]),
        position.count == 2, size.count == 3, let x = Double(position[0]), let baseline = Double(position[1]),
        let w = Double(size[0]), let h = Double(size[1]), let depth = Double(size[2]) else { continue }
      let scale = unit * magnification / 1000 / 65536 * 72 / 72.27
      let values = [(x + xOffset) * scale, (baseline - h + yOffset) * scale, w * scale, (h + depth) * scale]
      guard values.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }), scale > 0 else { throw invalid() }
      if kind == "(" {
        guard boxes.count < 4096 else { throw invalid() }
        boxes.append(values[2] > 0 && values[3] > 0 ? .init(x: values[0], y: values[1], width: values[2], height: values[3], lines: [line]) : nil)
      }
      guard address[0] == "1", let id = block(line) else { continue }
      if values[2] <= 0 || values[3] <= 0 { continue }
      guard result.count < 524_288 else { throw invalid() }
      result.append(.init(blockID: id, generatedLine: line, pageIndex: page,
        x: values[0], y: values[1], width: values[2], height: values[3]))
    }
    return result
  }
  /// SyncTeX can expose both a line and an enclosing box. Prefer the smallest
  /// containing box, otherwise the closest line; a macro still maps to its
  /// source line rather than an invented character inside its expansion.
  public static func nearest(in locations: [DocumentPrintLocation], blockID: String,
    pageIndex: Int, x: Double, y: Double) -> DocumentPrintLocation? {
    guard x.isFinite, y.isFinite else { return nil }
    func rank(_ value: DocumentPrintLocation) -> (Double, Double, Int) {
      let dx = max(value.x-x, 0, x-value.x-value.width)
      let dy = max(value.y-y, 0, y-value.y-value.height)
      return (dx*dx+dy*dy, value.width*value.height, value.generatedLine)
    }
    return locations.lazy.filter { $0.blockID == blockID && $0.pageIndex == pageIndex }
      .min { rank($0) < rank($1) }
  }
  public static func sourceOffset(line: Int, range: DocumentPrintSourceRange, source: String) -> Int {
    if let offsets = range.sourceOffsets, !offsets.isEmpty {
      return offsets[min(max(0, line-range.firstLine), offsets.count-1)]
    }
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    let local = min(max(0, line-range.firstLine), max(0, lines.count-1))
    return lines.prefix(local).reduce(0) { $0 + $1.utf16.count + 1 }
  }
  public static func generatedLine(sourceOffset: Int, range: DocumentPrintSourceRange, source: String) -> Int {
    if let offsets = range.sourceOffsets, !offsets.isEmpty {
      var low = 0, high = offsets.count
      while low < high { let mid = low+(high-low)/2; if offsets[mid] <= sourceOffset { low = mid+1 } else { high = mid } }
      let nearest = offsets[max(0, low-1)]
      // Choose the start, not trailing structural TeX with the same address.
      return range.firstLine + (offsets.firstIndex(of: nearest) ?? 0)
    }
    let prefix = (source as NSString).substring(to: min(max(0, sourceOffset), source.utf16.count))
    return range.firstLine + prefix.reduce(0) { $1 == "\n" ? $0+1 : $0 }
  }
  private static func invalid() -> CollaborationError {
    .init("invalid_print_locations", "Печатная карта не соответствует поддерживаемому SyncTeX или превышает предел адресов.")
  }
}
