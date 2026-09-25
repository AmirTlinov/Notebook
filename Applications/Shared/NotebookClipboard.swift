import Foundation
import CoreText
import ImageIO
import UniformTypeIdentifiers
import NotebookCore

/// Clipboard representations are input, never a second document or storage owner.
/// Only an explicit system paste (or the Mac menu command) calls this reader.
enum NotebookClipboard {
  static let fragmentType = UTType(exportedAs:"com.amirtlinov.notebook.fragment",conformingTo:.json)
  static let types: [UTType] = [fragmentType, .html, .json, .image, .url, .plainText]
  enum Content: Sendable {
    case composition(String)
    case fragment(NotebookPasteFragment)
  }
  private enum Item: Sendable {
    case text(String)
    case image(Data)
  }

  struct Export: Sendable {
    let fragment:Data
    let plainText:String?
    @MainActor var representations:[String:Any] {
      var item:[String:Any]=[fragmentType.identifier:fragment]
      if let plainText { item[UTType.utf8PlainText.identifier]=plainText }
      return item
    }
  }

  static func prepareExport(_ fragment:NotebookPasteFragment) throws -> Export {
    try Task.checkCancellation()
    let data=try JSONEncoder().encode(fragment)
    guard data.count <= 16 * 1_048_576 else { throw failure("Выделение слишком большое для буфера.") }
    try Task.checkCancellation()
    let text=fragment.elements.count == 1 && fragment.elements[0].kind == .nativeText ? fragment.elements[0].source : nil
    return .init(fragment:data,plainText:text)
  }

  @MainActor static func read(_ providers: [NSItemProvider], availableSize: SpatialPoint) async throws -> Content {
    guard !providers.isEmpty else { throw failure("Буфер пуст.") }
    guard providers.count <= 16 else { throw failure("За один раз можно вставить до 16 материалов.") }
    var items: [Item] = []
    var totalImageBytes = 0
    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(fragmentType.identifier) {
        guard providers.count == 1 else { throw failure("Вставьте выделение отдельно от других материалов.") }
        let bytes = try await data(provider,type:fragmentType,limit:16 * 1_048_576)
        let fragment = try JSONDecoder().decode(NotebookPasteFragment.self,from:bytes)
        return .fragment(try fragment.reidentified())
      }
      // HTML is inspected only for a structured envelope. Ordinary HTML never
      // enters WebKit: use its image/text representation instead, without a fetch.
      for type in [UTType.html, .json] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
        let source = try text(await data(provider, type: type, limit: 1_048_576))
        if NotebookTldrawImport.recognizes(source) {
          guard providers.count == 1 else { throw failure("Вставьте структурный фрагмент отдельно от других материалов.") }
          return .composition(source)
        }
      }
      if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        let image = try await data(provider, type: .image, limit: 20 * 1_048_576)
        totalImageBytes += image.count
        guard totalImageBytes <= 24 * 1_048_576 else { throw failure("Изображения слишком большие для одной вставки.") }
        items.append(.image(image))
      } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
        let value = try text(await data(provider, type: .url, limit: 65_536))
        guard URL(string: value)?.isFileURL != true else {
          throw failure("Вставка файлов пока не поддерживается. Скопируйте само изображение или текст.")
        }
        items.append(.text(value))
      } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
        let source = try text(await data(provider, type: .plainText, limit: 1_048_576))
        if NotebookTldrawImport.recognizes(source) {
          guard providers.count == 1 else { throw failure("Вставьте структурный фрагмент отдельно от других материалов.") }
          return .composition(source)
        }
        items.append(.text(source))
      } else if provider.hasItemConformingToTypeIdentifier(UTType.json.identifier) {
        items.append(.text(try text(await data(provider, type: .json, limit: 65_536))))
      } else {
        throw failure("Этот формат пока не поддерживается. Скопируйте текст, ссылку, изображение или элементы схемы.")
      }
    }
    let input = items
    let task = Task.detached(priority: .userInitiated) { try prepare(input, availableSize: availableSize) }
    return try await withTaskCancellationHandler { .fragment(try await task.value) } onCancel: { task.cancel() }
  }

  @MainActor private static func data(_ provider: NSItemProvider, type: UTType, limit: Int) async throws -> Data {
    try Task.checkCancellation()
    let data: Data = try await withCheckedThrowingContinuation { continuation in
      provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
        if let error { continuation.resume(throwing: error) }
        else if let data { continuation.resume(returning: data) }
        else { continuation.resume(throwing: failure("Не удалось прочитать буфер.")) }
      }
    }
    try Task.checkCancellation()
    guard data.count <= limit else { throw failure("Материал слишком большой. Скопируйте меньшую часть.") }
    return data
  }

  private static func text(_ data: Data) throws -> String {
    if let text = String(data: data, encoding: .utf8) { return text }
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
      let text = String(data: data, encoding: .utf16) { return text }
    throw failure("Не удалось прочитать текст в буфере.")
  }

  private struct Prepared {
    let kind: AgentElementKind
    let source: String
    let html: String
    let size: SpatialPoint
  }

  private static func prepare(_ items: [Item], availableSize: SpatialPoint) throws -> NotebookPasteFragment {
    guard availableSize.x.isFinite, availableSize.y.isFinite, availableSize.x > 0, availableSize.y > 0 else {
      throw failure("Поверхность вставки ещё не готова.")
    }
    let width = max(1, min(600, availableSize.x * 0.75))
    var prepared: [Prepared] = []
    for item in items {
      try Task.checkCancellation()
      switch item {
      case .text(let value):
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 65_536 else {
          throw failure("Нужен непустой текст не длиннее 64 КиБ.")
        }
        guard let font = CTFontCreateUIFontForLanguage(.system, 24, nil) else { throw failure("Системный шрифт недоступен.") }
        let attributed = NSAttributedString(string: value, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(attributed),
          CFRange(location: 0, length: 0), nil, CGSize(width: width, height: 100_000), nil)
        let size = SpatialPoint(x: min(width, max(48, ceil(measured.width) + 8)), y: max(40, ceil(measured.height * 1.2) + 8))
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLink = URL(string: trimmed).map { ["http", "https", "mailto"].contains($0.scheme?.lowercased() ?? "") && !trimmed.contains(where: \.isWhitespace) } ?? false
        let source = isLink ? "<\(trimmed)>" : value.map { "\\`*_{}[]<>()#+-.!|>".contains($0) ? "\\\($0)" : String($0) }.joined().replacingOccurrences(of: "\n", with: "  \n")
        let html = isLink ? "<p><a href=\"\(escape(trimmed))\">\(escape(value))</a></p>" : "<p>\(escape(value).replacingOccurrences(of: "\n", with: "<br>"))</p>"
        prepared.append(.init(kind: .markdown, source: source, html: html, size: size))
      case .image(let data):
        guard let input = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
          let w = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let h = properties[kCGImagePropertyPixelHeight] as? NSNumber,
          w.doubleValue > 0, h.doubleValue > 0, w.doubleValue * h.doubleValue <= 40_000_000,
          let image = CGImageSourceCreateThumbnailAtIndex(input, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
          throw failure("Изображение повреждено или превышает 40 мегапикселей.")
        }
        // Re-encode pixels, not metadata, remote URLs, SVG or executable HTML.
        let alpha = [.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo)
        let type: UTType = alpha ? .png : .jpeg
        let encoded = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(encoded, type.identifier as CFString, 1, nil) else { throw failure("Не удалось подготовить изображение.") }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(output), encoded.length <= 2 * 1_048_576 else { throw failure("Изображение слишком большое для вставки. Уменьшите его размер.") }
        let ratio = min(1, width / Double(image.width))
        prepared.append(.init(kind: .web, source: "Изображение", html: "<img alt=\"Изображение\" src=\"data:\(type.preferredMIMEType!);base64,\((encoded as Data).base64EncodedString())\">",
          size: .init(x: Double(image.width) * ratio, y: Double(image.height) * ratio)))
      }
      guard prepared.reduce(0, { $0 + $1.html.utf8.count }) <= 3 * 1_048_576 else { throw failure("Содержимое слишком большое для одной вставки.") }
    }
    let height = prepared.reduce(0, { $0 + $1.size.y }) + Double(max(0, prepared.count - 1)) * 16
    let factor = min(1, availableSize.y * 0.75 / max(1, height))
    var y = 0.0
    let elements = prepared.map { item in
      defer { y += (item.size.y + 16) * factor }
      return AgentElement(id: UUID().uuidString, kind: item.kind,
        frame: .init(x: 0, y: y, width: item.size.x * factor, height: item.size.y * factor),
        source: item.source, html: item.html,
        css: "html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden}p{margin:0;font: \(24 * factor)px/1.3 system-ui;white-space:pre-wrap;overflow-wrap:anywhere}img{display:block;width:100%;height:100%;object-fit:contain}")
    }
    return .init(elements: elements, size: .init(x: (prepared.map(\.size.x).max() ?? 1) * factor, y: height * factor))
  }

  private static func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }
  private static func failure(_ message: String) -> CollaborationError { .init("clipboard_unavailable", message) }
}
