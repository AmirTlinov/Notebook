import Foundation

/// Source Map v3 decoding for the one owned compiler input. It never resolves a
/// source URL. QuickJS adds one line; the TS async body has one wrapper line.
public struct NotebookTypeScriptSourceMap: Sendable {
  private struct Position: Sendable { let generatedColumn: Int; let line: Int; let column: Int }
  private let lines: [[Position]]
  public init(data: Data) throws {
    struct Map: Decodable { let version: Int; let sources: [String]; let mappings: String }
    guard data.count <= 1_048_576 else { throw CocoaError(.fileReadCorruptFile) }
    let map = try JSONDecoder().decode(Map.self, from: data)
    guard map.version == 3, map.sources.count == 1 else { throw CocoaError(.fileReadCorruptFile) }
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    let values = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, $0.offset) })
    var source = 0, originalLine = 0, originalColumn = 0, lines: [[Position]] = []
    for row in map.mappings.split(separator: ";", omittingEmptySubsequences: false) {
      var column = 0, positions: [Position] = []
      for segment in row.split(separator: ",") {
        var decoded: [Int] = [], value = 0, shift = 0
        for byte in segment.utf8 {
          guard let digit = values[byte], shift <= 25 else { throw CocoaError(.fileReadCorruptFile) }
          value |= (digit & 31) << shift
          if digit & 32 == 0 {
            decoded.append(value & 1 == 0 ? value >> 1 : -(value >> 1)); value = 0; shift = 0
          } else { shift += 5 }
        }
        guard shift == 0, [1, 4, 5].contains(decoded.count) else { throw CocoaError(.fileReadCorruptFile) }
        column += decoded[0]
        if decoded.count >= 4 {
          source += decoded[1]; originalLine += decoded[2]; originalColumn += decoded[3]
          guard source == 0, column >= 0, originalLine >= 0, originalColumn >= 0 else { throw CocoaError(.fileReadCorruptFile) }
          positions.append(.init(generatedColumn: column, line: originalLine, column: originalColumn))
        }
      }
      lines.append(positions)
    }
    self.lines = lines
  }
  public func map(_ diagnostic: String) -> String {
    let expression = try! NSRegularExpression(pattern: #"notebook-user\.js:(\d+)(?::(\d+))?"#)
    var result = diagnostic
    for match in expression.matches(in: diagnostic, range: NSRange(diagnostic.startIndex..., in: diagnostic)).reversed() {
      guard let lineRange = Range(match.range(at: 1), in: diagnostic), let line = Int(diagnostic[lineRange]),
        line >= 2, lines.indices.contains(line - 2), let range = Range(match.range, in: result) else { continue }
      let column = Range(match.range(at: 2), in: diagnostic).flatMap { Int(diagnostic[$0]) }.map { max(0, $0-1) } ?? 0
      let positions = lines[line - 2]
      guard let position = positions.last(where: { $0.generatedColumn <= column }) ?? positions.first, position.line > 0 else { continue }
      result.replaceSubrange(range, with: "notebook-user.ts:\(position.line):\(position.column+1)")
    }
    return result
  }
}
