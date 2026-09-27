import Foundation

/// Lexical source navigation, not a second TeX interpreter. Expanded macros
/// and physical links remain owned by the accepted compiler map and PDF.
public struct DocumentStructure: Codable, Sendable {
  public struct Entry: Codable, Sendable {
    public let kind: String
    public let fileID: String
    public let path: String
    public let line: Int
    public let utf16Offset: Int
    public let text: String
    public let instanceID: String?
  }
  public let documentID: UUID
  public let contentStamp: VersionStamp
  public let entries: [Entry]
  public init(document: DocumentDocument) {
    documentID = document.id; contentStamp = document.contentStamp
    var result: [Entry] = []
    let sections = Set(["part", "chapter", "section", "subsection", "subsubsection", "paragraph"])
    let references = Set(["ref", "eqref", "pageref", "autoref", "cref", "Cref"])
    let indexed = sections.union(references).union(["caption", "label", "NotebookInteractive"])
    for file in document.files where file.isText && (file.path as NSString).pathExtension == "tex" {
      let source = file.source as NSString
      var i = 0, line = 1
      func advance() { if source.character(at: i) == 10 { line += 1 }; i += 1 }
      func whitespace() { while i < source.length && [9, 10, 13, 32].contains(source.character(at: i)) { advance() } }
      func group(_ opening: unichar, _ closing: unichar) -> String? {
        guard i < source.length, source.character(at: i) == opening else { return nil }
        advance(); var depth = 1, text = ""
        while i < source.length {
          let c = source.character(at: i)
          if c == 37 { // An unescaped comment is not part of a title/path.
            while i < source.length && source.character(at: i) != 10 { advance() }
            continue
          }
          if c == 92, i + 1 < source.length {
            text += source.substring(with: NSRange(location: i, length: 2)); advance(); advance(); continue
          }
          if c == opening { depth += 1 }
          if c == closing { depth -= 1; if depth == 0 { advance(); return text } }
          // Append a complete Unicode scalar without splitting a surrogate pair.
          let count = (0xD800...0xDBFF).contains(c) && i + 1 < source.length ? 2 : 1
          text += source.substring(with: NSRange(location: i, length: count))
          for _ in 0..<count { advance() }
        }
        return nil
      }
      while i < source.length {
        let c = source.character(at: i)
        if c == 37 { while i < source.length && source.character(at: i) != 10 { advance() }; continue }
        guard c == 92 else { advance(); continue }
        let start = i, startLine = line; advance()
        let nameStart = i
        while i < source.length, (65...90).contains(source.character(at: i)) || (97...122).contains(source.character(at: i)) { advance() }
        let name = source.substring(with: NSRange(location: nameStart, length: i-nameStart))
        if name.isEmpty { if i < source.length { advance() }; continue }
        if i < source.length && source.character(at: i) == 42 { advance() }
        if name == "verb", i < source.length {
          let delimiter = source.character(at: i); advance()
          while i < source.length && source.character(at: i) != delimiter && source.character(at: i) != 10 { advance() }
          if i < source.length && source.character(at: i) == delimiter { advance() }
          continue
        }
        guard indexed.contains(name) || name == "begin" else { continue }
        whitespace(); let options = group(91, 93); whitespace()
        guard let text = group(123, 125) else { continue }
        if name == "begin" {
          if ["verbatim", "verbatim*", "Verbatim", "lstlisting", "minted"].contains(text) {
            let end = source.range(of: "\\end{\(text)}", range: NSRange(location: i, length: source.length-i))
            let through = end.location == NSNotFound ? source.length : NSMaxRange(end)
            while i < through { advance() }
          }
          continue
        }
        let kind = name == "NotebookInteractive" ? "program" : references.contains(name) ? "reference" : name == "label" ? "label" : name == "caption" ? "caption" : "section"
        let instanceID = name == "NotebookInteractive" ? options?.split(separator: ",").compactMap { option -> String? in
          let pair = option.split(separator: "=", maxSplits: 1)
          return pair.count == 2 && pair[0].trimmingCharacters(in: .whitespacesAndNewlines) == "id"
            ? pair[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }.first : nil
        result.append(.init(kind: kind, fileID: file.id, path: file.path, line: startLine, utf16Offset: start, text: text, instanceID: instanceID))
      }
    }
    entries = result
  }
}

extension NotebookStore {
  public func readDocumentStructure(documentID: UUID) throws -> DocumentStructure {
    try readTransaction { _ in .init(document: try loadDocument(documentID)) }
  }
}
