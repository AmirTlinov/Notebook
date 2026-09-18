import Foundation

/// Only decodes a data envelope. No HTML, script, asset URL or custom shape code
/// from the clipboard is executed. Both native paste and SDK use this boundary.
enum NotebookTldrawClipboard {
  static let maximumBytes = 1_048_576
  static let maximumExpandedBytes = 8_388_608

  static func content(_ source: String) throws -> JSONValue {
    guard source.utf8.count <= maximumBytes else { throw failure("Фрагмент превышает 1 МиБ. Скопируйте меньшую часть схемы.") }
    var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.hasPrefix("{"), let marker = text.range(of: #"<div\s+data-tldraw(?:=""|='')?(?:\s[^>]*)?>"#, options: .regularExpression) {
      guard let end = text.range(of: "</div>", options: .backwards, range: marker.upperBound..<text.endIndex) else { throw failure("Оборванный буфер tldraw.") }
      text = String(text[marker.upperBound..<end.lowerBound])
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&amp;", with: "&")
    }
    var value: JSONValue
    if text.hasPrefix("{") { value = try json(text) }
    else { value = try json(decompress(text)) }
    if value["type"]?.string == "application/tldraw" {
      guard value["kind"]?.string == "content", let payload = value["data"] else { throw failure("Нужен скопированный фрагмент tldraw.") }
      let version = value["version"]
      if version == .number(3) {
        guard let compressed = payload["otherCompressed"]?.string else { throw failure("В буфере нет структуры элементов.") }
        value = try json(decompress(compressed)).setting("assets", payload["assets"] ?? .array([]))
      } else if version == nil || version == .number(1) || version == .number(2) { value = payload }
      else { throw failure("Эта версия буфера tldraw ещё не поддерживается.") }
    }
    if let version = value["tldrawFileFormatVersion"] {
      guard version == .number(1), case .array(let records) = value["records"] else { throw failure("Неподдерживаемый формат файла tldraw.") }
      value = .object(["schema":value["schema"] ?? .null,
        "shapes":.array(records.filter { $0["typeName"]?.string == "shape" }),
        "bindings":.array(records.filter { $0["typeName"]?.string == "binding" })])
    }
    guard case .array = value["shapes"], value["schema"] != nil else { throw failure("Буфер не содержит структурный фрагмент tldraw. Используйте обычное «Копировать», не «Копировать как изображение».") }
    return value
  }

  private static func json(_ text: String) throws -> JSONValue {
    guard text.utf8.count <= maximumExpandedBytes else { throw failure("Распакованный фрагмент слишком большой.") }
    // Bound container nesting before the recursive decoder sees external data.
    var depth = 0, quoted = false, escaped = false
    for byte in text.utf8 {
      if escaped { escaped = false; continue }
      if quoted && byte == 92 { escaped = true; continue }
      if byte == 34 { quoted.toggle(); continue }
      if quoted { continue }
      if byte == 123 || byte == 91 { depth += 1 }
      if byte == 125 || byte == 93 { depth -= 1 }
      guard (0...96).contains(depth) else { throw failure("Слишком глубокая структура tldraw.") }
    }
    do { return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    catch { throw failure("Не удалось прочитать структуру tldraw.") }
  }

  /// LZ-string's base64 wire format (6-bit symbols, LSB-first codewords).
  /// Bounded output AND aggregate dictionary storage stop compressed bombs.
  static func decompress(_ input: String) throws -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    let lookup = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($0.element,$0.offset) })
    let bytes = Array(input.utf8)
    guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw failure("Пустой или слишком большой сжатый фрагмент.") }
    var symbols: [Int] = []
    var padding = false
    for byte in bytes {
      if byte == 61 { padding = true; continue }
      guard !padding, let value = lookup[byte] else { throw failure("Повреждённый base64 tldraw.") }
      symbols.append(value)
    }
    var bit = 0
    func read(_ count: Int) throws -> Int {
      guard count <= 24, bit + count <= symbols.count * 6 else { throw failure("Оборванный сжатый фрагмент tldraw.") }
      var result = 0
      for i in 0..<count {
        result |= ((symbols[bit / 6] >> (5 - bit % 6)) & 1) << i
        bit += 1
      }
      return result
    }
    let first = try read(2)
    if first == 2 { return "" }
    guard first < 2 else { throw failure("Некорректный код сжатия tldraw.") }
    var previous = [UInt16(try read(first == 0 ? 8 : 16))]
    var dictionary: [[UInt16]] = [[],[],[],previous]
    var output = previous, width = 3, remaining = 4, stored = 1
    func append(_ entry: [UInt16]) throws {
      stored += entry.count
      guard stored <= maximumExpandedBytes, dictionary.count < 1_048_576 else { throw failure("Словарь сжатого фрагмента превышает лимит.") }
      dictionary.append(entry)
    }
    while true {
      try Task.checkCancellation()
      var code = try read(width)
      if code == 2 { break }
      if code < 2 {
        try append([UInt16(try read(code == 0 ? 8 : 16))])
        code = dictionary.count - 1
        remaining -= 1
      }
      if remaining == 0 { remaining = 1 << width; width += 1 }
      let entry: [UInt16]
      if code < dictionary.count, !dictionary[code].isEmpty { entry = dictionary[code] }
      else if code == dictionary.count { entry = previous + [previous[0]] }
      else { throw failure("Повреждённый словарь tldraw.") }
      guard output.count + entry.count <= maximumExpandedBytes / 2 else { throw failure("Распакованный фрагмент превышает лимит.") }
      output.append(contentsOf: entry)
      try append(previous + [entry[0]])
      remaining -= 1; previous = entry
      if remaining == 0 { remaining = 1 << width; width += 1 }
    }
    let result = String(decoding: output, as: UTF16.self)
    guard Array(result.utf16) == output else { throw failure("Повреждённый Unicode tldraw.") }
    return result
  }

  static func failure(_ message: String) -> CollaborationError { .init("invalid_tldraw", message) }
}
