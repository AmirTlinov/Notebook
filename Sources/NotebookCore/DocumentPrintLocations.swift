import Foundation

/// Physical PDF points with a top-left origin; the camera is never an input.
public struct DocumentPrintLocation: Codable, Equatable, Sendable {
  public let fileID: String
  public let path: String
  public let line: Int
  public let pageIndex: Int
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double
}
public struct DocumentPrintInteractiveRegion: Codable, Equatable, Sendable {
  public let instanceID: String
  public let programPath: String
  public let pageIndex: Int
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double
  public let viewportY: Double
  public let viewportHeight: Double
}

public struct DocumentPrintProjection: Sendable {
  public let locations: [DocumentPrintLocation]
  public let interactiveRegions: [DocumentPrintInteractiveRegion]
  public func rebinding(files: [DocumentPrintSourceFile]) -> Self {
    let ids = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.fileID) })
    if locations.allSatisfy({ ids[$0.path] == $0.fileID }) { return self }
    return .init(locations: locations.compactMap { location in
      ids[location.path].map { .init(fileID: $0, path: location.path, line: location.line,
        pageIndex: location.pageIndex, x: location.x, y: location.y, width: location.width, height: location.height) }
    }, interactiveRegions: interactiveRegions)
  }
}

public enum DocumentPrintLocations {
  /// A single ordered shipout stream owns both source and program geometry.
  public static func decode(_ text: String, files: [DocumentPrintSourceFile], pages: [DocumentPrintPage]) throws -> DocumentPrintProjection {
    guard text.utf8.count <= 16*1024*1024, text.hasPrefix("SyncTeX Version:1\nNotebook Shipout:1\n"),
      (1...4096).contains(pages.count), pages.allSatisfy({
        [0, 90, 180, 270].contains($0.rotation) && [$0.width, $0.height].allSatisfy { $0.isFinite && $0 > 0 && $0 <= 1_000_000 }
      }), files.count <= 4096, Set(files.map(\.path)).count == files.count,
      files.allSatisfy({ $0.lineCount > 0 }) else { throw invalid() }
    let filesByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
    var inputs: [Int: DocumentPrintSourceFile] = [:]
    var page = -1, unit = 1.0, magnification = 1000.0, xOffset = 0.0, yOffset = 0.0
    var result: [DocumentPrintLocation] = [], regions: [DocumentPrintInteractiveRegion] = []
    var transform = PrintTransform.identity, transforms: [PrintTransform] = []
    struct LineBox {
      let x: Double, baseline: Double, width: Double, height: Double, depth: Double
      var addresses: Set<String>
    }
    var boxes: [LineBox?] = []
    func address(_ value: Substring) -> (DocumentPrintSourceFile, Int)? {
      let fields = value.split(separator: ",")
      guard fields.count >= 2, let tag = Int(fields[0]), let file = inputs[tag], let line = Int(fields[1]),
        (1...file.lineCount).contains(line) else { return nil }
      return (file, line)
    }
    func project(_ box: LineBox) throws -> DocumentPrintRect {
      let scale = unit*magnification/1000/65536*72/72.27
      let rect = pages[page].projectedBounds(x: (box.x+xOffset)*scale,
        y: pages[page].mediaBoxY+pages[page].mediaBoxHeight-(box.baseline+box.depth+yOffset)*scale,
        width: box.width*scale, height: (box.height+box.depth)*scale, content: transform)
      guard scale.isFinite, scale > 0, [rect.x, rect.y, rect.width, rect.height].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else { throw invalid() }
      return rect
    }
    func append(_ file: DocumentPrintSourceFile, _ line: Int, _ box: LineBox) throws {
      guard result.count < 524_288 else { throw invalid() }
      let rect = try project(box)
      result.append(.init(fileID: file.fileID, path: file.path, line: line, pageIndex: page,
        x: rect.x, y: rect.y, width: rect.width, height: rect.height))
    }
    for (ordinal, record) in text.split(separator: "\n").enumerated() {
      if ordinal % 1024 == 0 { try Task.checkCancellation() }
      if record.hasPrefix("Input:") {
        let fields = record.dropFirst(6).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2, let tag = Int(fields[0]), tag > 0 else { throw invalid() }
        var path = String(fields[1]); if path.hasPrefix("/input/") { path.removeFirst(7) }
        if path.hasPrefix("./") { path.removeFirst(2) }
        if let file = filesByPath[path] { inputs[tag] = file }
        continue
      }
      if record.hasPrefix("Unit:") { unit = Double(record.dropFirst(5)) ?? 0; continue }
      if record.hasPrefix("Magnification:") { magnification = Double(record.dropFirst(14)) ?? 0; continue }
      if record.hasPrefix("X Offset:") { xOffset = Double(record.dropFirst(9)) ?? .nan; continue }
      if record.hasPrefix("Y Offset:") { yOffset = Double(record.dropFirst(9)) ?? .nan; continue }
      if record.first == "{" {
        guard page == -1, transforms.isEmpty else { throw invalid() }
        page = (Int(record.dropFirst()) ?? 0)-1; boxes.removeAll(keepingCapacity: true)
        transform = .identity
        guard pages.indices.contains(page) else { throw invalid() }; continue
      }
      if record.first == "}" {
        guard transforms.isEmpty, Int(record.dropFirst()) == page+1 else { throw invalid() }
        page = -1; continue
      }
      if record.hasPrefix("N+"), page >= 0 {
        let (point, payload) = try special(record, page: pages[page])
        guard transforms.count < 256 else { throw invalid() }
        transforms.append(transform)
        transform = try transform.concatenating(.shipout(payload, pivot: point)); continue
      }
      if record.hasPrefix("N-"), page >= 0 {
        guard let previous = transforms.popLast() else { throw invalid() }
        transform = previous; continue
      }
      if record.hasPrefix("N!") { throw PrintTransform.unsupported() }
      if record.hasPrefix("N="), page >= 0 {
        let (point, payload) = try special(record, page: pages[page])
        let fields = payload.split(separator: "|", omittingEmptySubsequences: false)
        let scale = 72.0/72.27/65536
        guard fields.count == 6, (1...128).contains(fields[0].utf8.count),
          fields[0].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }),
          NotebookProgramPackage.validPath(String(fields[1])), let width = Double(fields[2]), let height = Double(fields[3]),
          let offset = Double(fields[4]), let total = Double(fields[5]),
          [width, height, offset, total].allSatisfy({ $0.isFinite && abs($0*scale) <= 1_000_000 }),
          width > 0, height > 0, offset >= 0, total >= offset+height, regions.count < 65_536 else { throw invalid() }
        let geometry = pages[page]
        let origin = geometry.projectPDF(transform.apply(point))
        let horizontal = geometry.projectPDF(transform.apply(.init(x: point.x+width*scale, y: point.y)))
        let vertical = geometry.projectPDF(transform.apply(.init(x: point.x, y: point.y+height*scale)))
        // WebKit's viewport is upright. Page orientation and pdflscape cancel
        // correctly; a separately rotated/sheared live viewport is not faked.
        guard abs(horizontal.y-origin.y) < 0.001, abs(vertical.x-origin.x) < 0.001,
          horizontal.x > origin.x, vertical.y < origin.y else {
          throw CollaborationError("unsupported_program_transform", "Живую область нельзя поворачивать отдельно от страницы или наклонять: \(fields[0]).")
        }
        let rect = geometry.projectedBounds(x: point.x, y: point.y, width: width*scale, height: height*scale, content: transform)
        let yScale = (origin.y-vertical.y)/(height*scale)
        guard [rect.x, rect.y, rect.width, rect.height].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else { throw invalid() }
        regions.append(.init(instanceID: String(fields[0]), programPath: String(fields[1]), pageIndex: page,
          x: rect.x, y: rect.y, width: rect.width, height: rect.height, viewportY: offset*scale*yScale, viewportHeight: total*scale*yScale))
        continue
      }
      if record.first == ")" { if !boxes.isEmpty { boxes.removeLast() }; continue }
      // Glyphs inherit a real line box and the current shipout transformation.
      if record.first == "g", page >= 0, let index = boxes.lastIndex(where: { $0 != nil }),
        let (file, line) = address(record.dropFirst().prefix { $0 != ":" }), var box = boxes[index],
        box.addresses.insert("\(file.fileID):\(line)").inserted {
        try append(file, line, box); boxes[index] = box; continue
      }
      guard page >= 0, let kind = record.first, ["(", "h", "v", "r"].contains(kind) else { continue }
      let fields = record.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
      guard fields.count >= 3 else { continue }
      let position = fields[1].split(separator: ","), size = fields[2].split(separator: ",")
      guard position.count == 2, size.count == 3, let x = Double(position[0]), let baseline = Double(position[1]),
        let w = Double(size[0]), let h = Double(size[1]), let depth = Double(size[2]) else { continue }
      let source = address(fields[0])
      let box = LineBox(x: x, baseline: baseline, width: w, height: h, depth: depth,
        addresses: source.map { ["\($0.0.fileID):\($0.1)"] } ?? [])
      if kind == "(" {
        guard boxes.count < 4096 else { throw invalid() }
        boxes.append(w > 0 && h+depth > 0 ? box : nil)
      }
      guard let (file, line) = source, w > 0, h+depth > 0 else { continue }
      try append(file, line, box)
    }
    guard page == -1, transforms.isEmpty else { throw invalid() }
    for group in Dictionary(grouping: regions, by: \.instanceID).values {
      let fragments = group.sorted { $0.viewportY < $1.viewportY }
      var offset = 0.0
      for region in fragments {
        guard region.programPath == fragments[0].programPath, abs(region.width-fragments[0].width) < 0.001,
          abs(region.viewportHeight-fragments[0].viewportHeight) < 0.001, abs(region.viewportY-offset) < 0.001 else { throw invalid() }
        offset += region.height
      }
      guard abs(offset-fragments[0].viewportHeight) < 0.001 else { throw invalid() }
    }
    return .init(locations: result, interactiveRegions: regions)
  }
  private static func special(_ record: Substring, page: DocumentPrintPage) throws -> (PrintPoint, Substring) {
    let fields = record.dropFirst(2).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard fields.count == 2 else { throw invalid() }
    let values = fields[0].split(separator: ",")
    let scale = 72.0/72.27/65536
    guard values.count == 2, let x = Double(values[0]), let y = Double(values[1]),
      [x, y].allSatisfy({ $0.isFinite && abs($0*scale) <= 1_000_000 }) else { throw invalid() }
    return (.init(x: x*scale, y: page.mediaBoxY+page.mediaBoxHeight-y*scale), fields[1])
  }
  /// Prefer the smallest containing line box, otherwise the closest line.
  public static func nearest(in locations: [DocumentPrintLocation], fileID: String,
    pageIndex: Int, x: Double, y: Double) -> DocumentPrintLocation? {
    guard x.isFinite, y.isFinite else { return nil }
    func rank(_ value: DocumentPrintLocation) -> (Double, Double, Int) {
      let dx = max(value.x-x, 0, x-value.x-value.width), dy = max(value.y-y, 0, y-value.y-value.height)
      return (dx*dx+dy*dy, value.width*value.height, value.line)
    }
    return locations.lazy.filter { $0.fileID == fileID && $0.pageIndex == pageIndex }.min { rank($0) < rank($1) }
  }
  public static func sourceOffset(line: Int, source: String) -> Int {
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    return lines.prefix(min(max(0, line-1), max(0, lines.count-1))).reduce(0) { $0+$1.utf16.count+1 }
  }
  public static func line(sourceOffset: Int, source: String) -> Int {
    let prefix = (source as NSString).substring(to: min(max(0, sourceOffset), source.utf16.count))
    return prefix.reduce(1) { $1 == "\n" ? $0+1 : $0 }
  }
  private static func invalid() -> CollaborationError {
    .init("invalid_print_locations", "Печатная карта не соответствует поддерживаемому формату или превышает предел адресов.")
  }
}
