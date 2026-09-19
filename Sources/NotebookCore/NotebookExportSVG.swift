import Foundation

/// An exported SVG is a passive, closed image. Its author can choose geometry,
/// not add filesystem/network/script capabilities by moving out of the sandbox.
public enum NotebookExportSVG {
  public static func validate(_ data: Data) throws {
    guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8),
      !text.lowercased().contains("<!doctype"), !text.lowercased().contains("<!entity") else { throw invalid() }
    let delegate = Validator(), parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
    guard parser.parse(), delegate.valid, delegate.root else { throw invalid() }
  }
  private static func invalid() -> CollaborationError {
    CollaborationError("invalid_export_svg", "Нужен замкнутый статический SVG до 1 МиБ: без script, foreignObject, внешних ссылок, CSS, внешних ссылок и анимации.")
  }
  private final class Validator: NSObject, XMLParserDelegate {
    var valid = true, root = false
    private let tags = Set("svg g defs symbol use path rect circle ellipse line polyline polygon text tspan textPath title desc clipPath mask marker pattern linearGradient radialGradient stop image filter feBlend feColorMatrix feComponentTransfer feComposite feConvolveMatrix feDiffuseLighting feDisplacementMap feDistantLight feDropShadow feFlood feFuncA feFuncB feFuncG feFuncR feGaussianBlur feMerge feMergeNode feMorphology feOffset fePointLight feSpecularLighting feSpotLight feTile feTurbulence".split(separator: " ").map(String.init))
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
      guard namespaceURI == "http://www.w3.org/2000/svg", tags.contains(name), root || name == "svg" else { reject(parser); return }
      root = true
      for (key, value) in attributes {
        let key = key.lowercased(), trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.hasPrefix("on"), key != "xml:base", key != "style", safeURL(value) else { reject(parser); return }
        if key == "href" || key.hasSuffix(":href") {
          guard trimmed.hasPrefix("#") || (name == "image" && ["data:image/png;base64,", "data:image/jpeg;base64,", "data:image/webp;base64,"].contains(where: trimmed.hasPrefix)) else { reject(parser); return }
        }
      }
    }
    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) { reject(parser) }
    private func reject(_ parser: XMLParser) { valid = false; parser.abortParsing() }
    private func safeURL(_ value: String) -> Bool {
      // Only literal presentation attributes and local paint-server IDs; no CSS
      // stylesheets or style attributes with additional URL-bearing grammars.
      guard !value.contains("\\"), !value.contains("@") else { return false }
      let expression = try! NSRegularExpression(pattern: #"(?i)url\s*\(\s*([^)]+)(?:\)|$)"#)
      let string = value as NSString
      return expression.matches(in: value, range: NSRange(location: 0, length: string.length)).allSatisfy {
        string.substring(with: $0.range(at: 1)).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "\"'"))).hasPrefix("#")
      }
    }
  }
}
