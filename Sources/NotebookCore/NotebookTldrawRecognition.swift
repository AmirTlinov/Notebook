/// Representation identity is a bounded prefix read, not content validation.
/// Once its explicit marker is seen, a damaged/oversized envelope must reach
/// the importer and refuse there instead of falling back to its text labels.
enum NotebookTldrawRecognition {
  static func recognizes(_ source: String) -> Bool {
    var cursor = Cursor(source)
    cursor.skipWhitespace()
    switch cursor.peek {
    case 123: return cursor.jsonObject()
    case 34, 91: return false
    // CF_HTML headers and ordinary preambles can precede the actual tags.
    // JSON strings/arrays remain opaque rather than exposing their labels.
    default: return cursor.html()
    }
  }

  private struct Cursor {
    private let bytes: String.UTF8View
    private var index: String.UTF8View.Index
    private var remaining = NotebookTldrawClipboard.maximumBytes
    init(_ source: String) {
      bytes = source.utf8; index = bytes.startIndex
      if bytes.starts(with: [0xef, 0xbb, 0xbf]) { for _ in 0..<3 { _ = pop() } }
    }
    var peek: UInt8? { remaining > 0 && index != bytes.endIndex ? bytes[index] : nil }
    @discardableResult mutating func pop() -> UInt8? {
      guard let byte = peek else { return nil }
      bytes.formIndex(after: &index); remaining -= 1; return byte
    }
    mutating func take(_ byte: UInt8) -> Bool {
      guard peek == byte else { return false }; _ = pop(); return true
    }
    private func whitespace(_ byte: UInt8, html: Bool = false) -> Bool {
      [9, 10, 13, 32].contains(byte) || (html && byte == 12)
    }
    mutating func skipWhitespace(html: Bool = false) {
      while let byte = peek, whitespace(byte, html: html) { _ = pop() }
    }

    mutating func jsonObject() -> Bool {
      _ = pop()
      var hasSchema = false, hasShapes = false
      while peek != nil {
        skipWhitespace()
        guard let key = string(capturing: true) else { return false }
        skipWhitespace()
        guard take(58) else { return false }
        skipWhitespace()
        switch key {
        case "type":
          if peek == 34 {
            guard let identity = string(capturing: true) else { return false }
            if identity == "application/tldraw" { return true }
          } else if !skipValue() { return false }
        case "tldrawFileFormatVersion": return true
        case "schema":
          hasSchema = true
          if hasShapes { return true }
          guard skipValue() else { return false }
        case "shapes":
          hasShapes = peek == 91
          if hasSchema && hasShapes { return true }
          guard skipValue() else { return false }
        default: guard skipValue() else { return false }
        }
        skipWhitespace()
        guard take(44) else { return false }
      }
      return false
    }

    /// Only the short ASCII identity names need decoded storage. JSON escapes
    /// can spell those same names; arbitrary labels are scanned without copies.
    private mutating func string(capturing: Bool) -> String? {
      guard take(34) else { return nil }
      var ascii: [UInt8] = [], captures = capturing
      while let byte = pop() {
        if byte == 34 { return captures ? String(decoding: ascii, as: UTF8.self) : "" }
        guard byte >= 0x20 else { return nil }
        var scalar = Int(byte)
        if byte == 92 {
          guard let escape = pop() else { return nil }
          switch escape {
          case 34, 47, 92: scalar = Int(escape)
          case 98: scalar = 8
          case 102: scalar = 12
          case 110: scalar = 10
          case 114: scalar = 13
          case 116: scalar = 9
          case 117:
            scalar = 0
            for _ in 0..<4 {
              guard let digit = pop() else { return nil }
              let value: Int
              switch digit {
              case 48...57: value = Int(digit - 48)
              case 65...70: value = Int(digit - 65 + 10)
              case 97...102: value = Int(digit - 97 + 10)
              default: return nil
              }
              scalar = scalar * 16 + value
            }
          default: return nil
          }
        }
        if captures && scalar < 128 && ascii.count < 32 { ascii.append(UInt8(scalar)) }
        else { captures = false }
      }
      return nil
    }

    private mutating func skipValue() -> Bool {
      guard let first = peek else { return false }
      if first == 34 { return string(capturing: false) != nil }
      if first == 123 || first == 91 {
        var closing: [UInt8] = []
        while let byte = peek {
          switch byte {
          case 34: guard string(capturing: false) != nil else { return false }
          case 123, 91:
            // Include the already-open root. This probe can reach a format
            // header after every subtree admitted by the Core JSON boundary.
            guard closing.count < NotebookJSONAdmission.maximumDepth - 1 else { return false }
            closing.append(byte == 123 ? 125 : 93); _ = pop()
          case 125, 93:
            guard closing.popLast() == byte else { return false }
            _ = pop()
            if closing.isEmpty { return true }
          default: _ = pop()
          }
        }
        return false
      }
      switch first {
      case 116: guard literal("true") else { return false }
      case 102: guard literal("false") else { return false }
      case 110: guard literal("null") else { return false }
      default: guard number() else { return false }
      }
      return peek.map { whitespace($0) || [44, 93, 125].contains($0) } ?? true
    }
    private mutating func literal(_ value: StaticString) -> Bool {
      for byte in value.withUTF8Buffer({ Array($0) }) { guard take(byte) else { return false } }
      return true
    }
    private mutating func digits() -> Bool {
      var found = false
      while let byte = peek, (48...57).contains(byte) { _ = pop(); found = true }
      return found
    }
    private mutating func number() -> Bool {
      _ = take(45)
      if !take(48) { guard let byte = peek, (49...57).contains(byte), digits() else { return false } }
      if take(46), !digits() { return false }
      if take(101) || take(69) {
        if !take(43) { _ = take(45) }
        guard digits() else { return false }
      }
      return true
    }

    mutating func html() -> Bool {
      while let byte = pop() {
        guard byte == 60 else { continue }
        if take(33) {
          if take(45) && take(45) { skipComment() } else { skipTag() }
          continue
        }
        if take(47) || take(63) { skipTag(); continue }
        guard let tag = word() else { continue }
        while peek != nil {
          skipWhitespace(html: true)
          if take(62) { break }
          if take(47) { skipTag(); break }
          guard let attribute = word() else { skipTag(); break }
          let boundary = peek.map { whitespace($0, html: true) || [61, 62, 47].contains($0) } ?? true
          if tag == "div", attribute == "data-tldraw", boundary { return true }
          skipWhitespace(html: true)
          if take(61) {
            skipWhitespace(html: true)
            if let quote = peek, quote == 34 || quote == 39 {
              _ = pop(); while let next = pop(), next != quote {}
            } else {
              while let next = peek, !whitespace(next, html: true), next != 62 { _ = pop() }
            }
          }
        }
        if ["script", "style", "textarea", "title"].contains(tag) { skipRawText(tag) }
        if tag == "plaintext" { return false }
      }
      return false
    }
    private mutating func word() -> String? {
      var name: [UInt8] = [], tooLong = false
      while let byte = peek, (65...90).contains(byte) || (97...122).contains(byte)
        || (48...57).contains(byte) || [45, 58, 95].contains(byte) {
        _ = pop()
        if name.count < 32 { name.append((65...90).contains(byte) ? byte + 32 : byte) }
        else { tooLong = true }
      }
      return name.isEmpty || tooLong ? nil : String(decoding: name, as: UTF8.self)
    }
    private mutating func skipTag() {
      var quote: UInt8?
      while let byte = pop() {
        if let current = quote { if byte == current { quote = nil } }
        else if byte == 34 || byte == 39 { quote = byte }
        else if byte == 62 { return }
      }
    }
    private mutating func skipComment() {
      var dashes = 0
      while let byte = pop() {
        if byte == 62 && dashes >= 2 { return }
        dashes = byte == 45 ? dashes + 1 : 0
      }
    }
    private mutating func skipRawText(_ tag: String) {
      while let byte = pop() {
        if byte == 60, take(47), word() == tag,
          peek.map({ whitespace($0, html: true) || $0 == 62 }) ?? false { skipTag(); return }
      }
    }
  }
}
