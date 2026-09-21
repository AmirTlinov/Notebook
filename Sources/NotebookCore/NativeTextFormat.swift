import Foundation

/// Character formatting is content, not a view or editor preference. UTF-16
/// ranges match native text selection on both platforms; runs never overlap.
public struct NativeTextFormat: Codable, Hashable, Sendable {
  public var fontName: String?
  public var bold: Bool?
  public var italic: Bool?
  public var highlight: SpatialInkColor?
  public var link: String?
  public init(fontName: String? = nil, bold: Bool? = nil, italic: Bool? = nil,
    highlight: SpatialInkColor? = nil, link: String? = nil) {
    self.fontName = fontName; self.bold = bold; self.italic = italic
    self.highlight = highlight; self.link = link
  }
  var isValid: Bool {
    (fontName == nil || (!fontName!.isEmpty && fontName!.utf16.count <= 160))
      && (highlight?.isValid ?? true) && (link == nil || Self.isWebLink(link!))
  }
  public static func isWebLink(_ value: String) -> Bool {
    guard value.utf16.count <= 4096, let url = URL(string:value), let scheme = url.scheme?.lowercased() else { return false }
    return (["https","http"].contains(scheme) && url.host?.isEmpty == false) || (scheme == "mailto" && !url.path.isEmpty)
  }
}

public struct NativeTextRun: Codable, Equatable, Sendable {
  public var location: Int
  public var length: Int
  public var format: NativeTextFormat
  public init(location: Int, length: Int, format: NativeTextFormat) {
    self.location = location; self.length = length; self.format = format
  }
}
