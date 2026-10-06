import Foundation
import NotebookCore
import CNotebookTypesetter

extension NotebookPrintedDocument {
  public struct CacheAdoptionCost: Sendable {
    public let decodedBytes: Int
    public let projectionBytes: Int
    public var bytes: Int { decodedBytes * 3 + projectionBytes + 1_048_576 }
    init(decodedBytes: Int, projectionBytes: Int) {
      self.decodedBytes = decodedBytes; self.projectionBytes = projectionBytes
    }
    func validate(_ derived: NotebookPortableDocument.Derived) throws {
      let required = try NotebookPrintedDocument.cacheAdoptionCost(derived)
      guard decodedBytes == required.decodedBytes, projectionBytes == required.projectionBytes else {
        throw NotebookTypesetterError("print_cache_admission_limit")
      }
    }
  }
  public static func cacheAdoptionCost(_ derived: NotebookPortableDocument.Derived) throws -> CacheAdoptionCost {
    let size = decodedSize(derived.syncTeX)
    guard (1...16*1_048_576).contains(size) else { throw NotebookTypesetterError("print_locations_decode_limit") }
    // A glyph address needs at least five wire characters. Locations borrow
    // file/path strings; address sets and authored region strings have their
    // separate charge before insertion. The parser stops at this finite credit.
    let records = min(524_288, size / 5 + 1)
    let longestID = derived.sourceMap.files.map { $0.fileID.utf8.count }.max() ?? 0
    let perRecord = MemoryLayout<DocumentPrintLocation>.stride * 2 + (longestID+20)*2 + 256
    let projection = min(DocumentPrintLocations.maximumAllocationBytes,
      1_048_576 + derived.sourceMap.files.count*512 + records*perRecord + size*4)
    return .init(decodedBytes: size, projectionBytes: projection)
  }
  public func locations() throws -> [DocumentPrintLocation] {
    projection.locations
  }
  static func regionMap(_ regions: [DocumentPrintInteractiveRegion]) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let map = try encoder.encode(regions)
    guard map.count <= 4*1024*1024 else { throw NotebookTypesetterError("print_region_map_limit") }
    return map
  }
  static func projection(syncTeX: Data, files: [DocumentPrintSourceFile], pages: [DocumentPrintPage],
    allocationBytes: Int = DocumentPrintLocations.maximumAllocationBytes) throws -> DocumentPrintProjection {
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
    return try DocumentPrintLocations.decode(text, files: files, pages: pages, allocationBytes: allocationBytes)
  }
  private static func decodedSize(_ data: Data) -> Int {
    guard data.count >= 4 else { return 0 }
    return data.suffix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset*8)) }
  }
}
