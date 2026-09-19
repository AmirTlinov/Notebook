import Foundation
import NotebookCore
import CNotebookTypesetter

extension NotebookPrintedDocument {
  public var locationDecodeBytes: Int {
    guard syncTeX.count >= 4 else { return 0 }
    return syncTeX.suffix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset*8)) }
  }
  public func locations() throws -> [DocumentPrintLocation] {
    guard !syncTeX.isEmpty else { return [] }
    try Task.checkCancellation()
    guard (1...16*1024*1024).contains(locationDecodeBytes) else { throw NotebookTypesetterError("print_locations_decode_limit") }
    var data = Data(count: locationDecodeBytes), count = data.count
    let status = data.withUnsafeMutableBytes { target in syncTeX.withUnsafeBytes { source in
      nb_typesetter_inflate(source.bindMemory(to: UInt8.self).baseAddress, syncTeX.count,
        target.bindMemory(to: UInt8.self).baseAddress, &count)
    } }
    guard status == 0 else { throw NotebookTypesetterError("print_locations_decode_failed") }
    data.count = count
    guard let text = String(data: data, encoding: .utf8) else { throw NotebookTypesetterError("print_locations_encoding") }
    return try DocumentPrintLocations.decode(text, ranges: sourceMap.ranges)
  }
}
