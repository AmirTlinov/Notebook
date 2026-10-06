import Foundation

/// Text semantics of the search recipe. Authored source remains literal;
/// only an explicitly selected HTML fallback is parsed. This is structural
/// text extraction, with no script execution, CSS/layout or resource loading.
enum NotebookSearchText {
  static let maximumHTMLBytes = 8 * 1_024 * 1_024
  static let maximumTextBytes = 8 * 1_024 * 1_024

  static func plain(_ value: String) throws -> String {
    guard value.utf8.count <= maximumTextBytes else { throw NotebookStorageError.limitExceeded("search_text_bytes") }
    return value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  static func element(_ value: JSONValue) throws -> String {
    switch value["kind"]?.string {
    case "group": return ""
    case "graphic":
      guard let graphic = value["graphic"], graphic["visible"] != .bool(false),
        graphic["representation"] != .string("ink") else { return "" }
      return try plain(graphic["label"]?.string ?? "")
    case "nativeText": return try plain(value["source"]?.string ?? "")
    default:
      let source = value["source"]?.string ?? ""
      if !source.isEmpty { return try plain(source) }
      return try html(value["html"]?.string ?? "")
    }
  }

  /// Preserve literal '<' outside recognized markup and unknown entities.
  /// An unfinished tag/comment/raw-text element contributes no remaining
  /// markup body; unbalanced ordinary element boundaries need no DOM repair.
  /// Encoded markup is decoded once into text, never parsed a second time.
  static func html(_ source: String) throws -> String {
    guard source.utf8.count <= maximumHTMLBytes else {
      throw NotebookStorageError.limitExceeded("search_html_bytes")
    }
    let bytes = Array(source.utf8)
    var output: [UInt8] = []
    output.reserveCapacity(min(bytes.count, 65_536))
    var index = 0, suppressed: [String] = []
    var raw: String?
    func space() { if !output.isEmpty, output.last != 32 { output.append(32) } }
    while index < bytes.count {
      if let name = raw {
        if startsClosing(bytes, at: index, name: name) {
          guard let tag = tag(bytes, at: index) else { break }
          raw = nil; index = tag.end
        } else {
          if suppressed.isEmpty, name == "textarea" || name == "title" {
            if bytes[index] == 38, let entity = entity(bytes, at: index) {
              output.append(contentsOf: entity.text.utf8); index = entity.end; continue
            }
            output.append(bytes[index])
          }
          index += 1
        }
        continue
      }
      if bytes[index] == 60 {
        if matches(bytes, at: index, ascii: "<!--") {
          index += 4
          while index < bytes.count, !matches(bytes, at: index, ascii: "-->") { index += 1 }
          index = min(bytes.count, index + 3)
          continue
        }
        if let tag = tag(bytes, at: index) {
          if tag.name == "head" || tag.name == "template" {
            if tag.closing {
              if let matching = suppressed.lastIndex(of: tag.name) { suppressed.removeSubrange(matching...) }
            } else {
              guard suppressed.count < 256 else { throw NotebookStorageError.limitExceeded("search_html_depth") }
              suppressed.append(tag.name)
            }
          }
          if suppressed.isEmpty, blocks.contains(tag.name) { space() }
          if !tag.closing, ["script", "style", "textarea", "title"].contains(tag.name) { raw = tag.name }
          index = tag.end
          continue
        }
        // '<letter' is an unfinished tag, not author-visible trailing text.
        let next = index + 1
        if next < bytes.count, letter(bytes[next]) || [33, 47, 63].contains(bytes[next]) { break }
      }
      if suppressed.isEmpty {
        if bytes[index] == 38, let entity = entity(bytes, at: index) {
          output.append(contentsOf: entity.text.utf8); index = entity.end; continue
        }
        output.append(bytes[index])
      }
      index += 1
    }
    return try plain(String(decoding: output, as: UTF8.self))
  }

  private struct Tag { let name: String; let closing: Bool; let end: Int }
  private static func tag(_ bytes: [UInt8], at start: Int) -> Tag? {
    var index = start + 1
    guard index < bytes.count else { return nil }
    var closing = false
    if bytes[index] == 47 { closing = true; index += 1 }
    guard index < bytes.count else { return nil }
    let declaration = bytes[index] == 33 || bytes[index] == 63
    guard declaration || letter(bytes[index]) else { return nil }
    let begin = index
    if declaration { index += 1 }
    else {
      while index < bytes.count, letter(bytes[index]) || digit(bytes[index]) || [45, 58, 95].contains(bytes[index]) { index += 1 }
      guard index < bytes.count, whitespace(bytes[index]) || bytes[index] == 47 || bytes[index] == 62 else { return nil }
    }
    // Only short semantic names matter. Unknown/custom tags still delimit
    // markup, without allocating a potentially multi-megabyte tag name.
    let name = !declaration && index - begin <= 32
      ? String(decoding: bytes[begin..<index].map(lower), as: UTF8.self) : ""
    var quote: UInt8?
    while index < bytes.count {
      let byte = bytes[index]
      if let delimiter = quote { if byte == delimiter { quote = nil } }
      else if byte == 34 || byte == 39 { quote = byte }
      else if byte == 62 { return .init(name: name, closing: closing, end: index + 1) }
      else if byte == 60 { return nil }
      index += 1
    }
    return nil
  }

  private static func entity(_ bytes: [UInt8], at start: Int) -> (text: String, end: Int)? {
    var end = start + 1
    while end < bytes.count, end - start <= 32, bytes[end] != 59 {
      guard letter(bytes[end]) || digit(bytes[end]) || bytes[end] == 35 else { return nil }
      end += 1
    }
    guard end < bytes.count, bytes[end] == 59, end - start <= 32 else { return nil }
    let name = String(decoding: bytes[(start + 1)..<end], as: UTF8.self)
    if name.hasPrefix("#") {
      let hex = name.hasPrefix("#x") || name.hasPrefix("#X")
      guard let value = UInt32(name.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10) else { return nil }
      let mapped = windowsNumerics[value] ?? value
      let scalar = mapped == 0 ? nil : UnicodeScalar(mapped)
      return (scalar.map(String.init) ?? "\u{fffd}", end + 1)
    }
    return entities[name].map { ($0, end + 1) }
  }

  private static func matches(_ bytes: [UInt8], at start: Int, ascii: StaticString) -> Bool {
    ascii.withUTF8Buffer { expected in
      guard start + expected.count <= bytes.count else { return false }
      for offset in expected.indices where bytes[start + offset] != expected[offset] { return false }
      return true
    }
  }
  private static func startsClosing(_ bytes: [UInt8], at start: Int, name: String) -> Bool {
    guard start + name.utf8.count + 2 < bytes.count, bytes[start] == 60, bytes[start + 1] == 47 else { return false }
    for (offset, byte) in name.utf8.enumerated() where lower(bytes[start + 2 + offset]) != byte { return false }
    let next = bytes[start + 2 + name.utf8.count]
    return whitespace(next) || next == 62 || next == 47
  }
  private static func lower(_ byte: UInt8) -> UInt8 { (65...90).contains(byte) ? byte + 32 : byte }
  private static func letter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
  private static func digit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
  private static func whitespace(_ byte: UInt8) -> Bool { [9, 10, 12, 13, 32].contains(byte) }

  private static let blocks: Set<String> = ["address", "article", "aside", "blockquote", "br", "dd", "div", "dl", "dt",
    "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr",
    "li", "main", "nav", "ol", "p", "pre", "section", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul"]
  private static let entities: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
    "nbsp": "\u{a0}", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "copy": "©", "reg": "®",
    "trade": "™", "ndash": "–", "mdash": "—", "hellip": "…", "bull": "•", "middot": "·", "times": "×", "divide": "÷",
    "plusmn": "±", "minus": "−", "le": "≤", "ge": "≥", "ne": "≠", "larr": "←", "rarr": "→", "harr": "↔",
    "uarr": "↑", "darr": "↓", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "para": "¶",
    "laquo": "«", "raquo": "»", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
    "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä", "Aring": "Å", "AElig": "Æ", "Ccedil": "Ç",
    "Egrave": "È", "Eacute": "É", "Ecirc": "Ê", "Euml": "Ë", "Igrave": "Ì", "Iacute": "Í", "Icirc": "Î", "Iuml": "Ï",
    "ETH": "Ð", "Ntilde": "Ñ", "Ograve": "Ò", "Oacute": "Ó", "Ocirc": "Ô", "Otilde": "Õ", "Ouml": "Ö", "Oslash": "Ø",
    "Ugrave": "Ù", "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü", "Yacute": "Ý", "THORN": "Þ", "szlig": "ß",
    "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã", "auml": "ä", "aring": "å", "aelig": "æ", "ccedil": "ç",
    "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë", "igrave": "ì", "iacute": "í", "icirc": "î", "iuml": "ï",
    "eth": "ð", "ntilde": "ñ", "ograve": "ò", "oacute": "ó", "ocirc": "ô", "otilde": "õ", "ouml": "ö", "oslash": "ø",
    "ugrave": "ù", "uacute": "ú", "ucirc": "û", "uuml": "ü", "yacute": "ý", "thorn": "þ", "yuml": "ÿ",
    "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "theta": "θ", "lambda": "λ", "mu": "μ",
    "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ", "psi": "ψ", "omega": "ω"]
  private static let windowsNumerics: [UInt32: UInt32] = [128: 0x20ac, 130: 0x201a, 131: 0x0192, 132: 0x201e,
    133: 0x2026, 134: 0x2020, 135: 0x2021, 136: 0x02c6, 137: 0x2030, 138: 0x0160, 139: 0x2039, 140: 0x0152,
    142: 0x017d, 145: 0x2018, 146: 0x2019, 147: 0x201c, 148: 0x201d, 149: 0x2022, 150: 0x2013, 151: 0x2014,
    152: 0x02dc, 153: 0x2122, 154: 0x0161, 155: 0x203a, 156: 0x0153, 158: 0x017e, 159: 0x0178]
}
