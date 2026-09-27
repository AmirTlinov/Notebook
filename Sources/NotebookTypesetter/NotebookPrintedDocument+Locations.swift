import Foundation
import NotebookCore
import CNotebookTypesetter

extension NotebookPrintedDocument {
  public func locations() throws -> [DocumentPrintLocation] {
    projection.locations
  }
  static func regionMap(_ regions: [DocumentPrintInteractiveRegion]) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let map = try encoder.encode(regions)
    guard map.count <= 4*1024*1024 else { throw NotebookTypesetterError("print_region_map_limit") }
    return map
  }
  static func projection(syncTeX: Data, files: [DocumentPrintSourceFile], pages: [DocumentPrintPage]) throws -> DocumentPrintProjection {
    try Task.checkCancellation()
    let size = decodedSize(syncTeX)
    guard (1...16*1024*1024).contains(size) else { throw NotebookTypesetterError("print_locations_decode_limit") }
    var data = Data(count: size), count = size
    let status = data.withUnsafeMutableBytes { target in syncTeX.withUnsafeBytes { source in
      nb_typesetter_inflate(source.bindMemory(to: UInt8.self).baseAddress, syncTeX.count,
        target.bindMemory(to: UInt8.self).baseAddress, &count)
    } }
    guard status == 0, count == size else { throw NotebookTypesetterError("print_locations_decode_failed") }
    guard let text = String(data: data, encoding: .utf8) else { throw NotebookTypesetterError("print_locations_encoding") }
    return try DocumentPrintLocations.decode(text, files: files, pages: pages)
  }
  private static func decodedSize(_ data: Data) -> Int {
    guard data.count >= 4 else { return 0 }
    return data.suffix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset*8)) }
  }
}
