import NotebookCore
import SwiftUI
#if os(iOS)
import UIKit
private typealias NativeFont = UIFont
private typealias NativeColor = UIColor
#else
import AppKit
private typealias NativeFont = NSFont
private typealias NativeColor = NSColor
#endif

/// TextKit and the static scene consume the same attributed content. There is
/// no Markdown heuristic, HTML renderer, or second rich-text document.
enum NotebookTextTypography {
  static let fonts: [(name: String?, title: String)] = [(nil,"Системный"),("Georgia","С засечками"),
    ("Menlo-Regular","Моноширинный"),("ChalkboardSE-Regular","Рукописный"),("Noteworthy-Light","Заметки")]
  private static let formatKey = NSAttributedString.Key("notebook.nativeTextFormat")

  /// The authored frame is a text layout constraint, not a minimum selection
  /// size. Rendering and contact admission use this fitted extent; width grips
  /// expose the actual line constraint rather than the last glyph's position.
  static func fittingFrame(_ text: String, style: NativeTextStyle, in frame: PageRect) -> PageRect {
    guard !text.isEmpty else { return frame }
    // Match Text's line metrics. Opting into legacy font leading on macOS
    // can measure six 24-point lines as 138 rather than 144 and truncate them.
    let rect = attributed(text,style:style).boundingRect(with:.init(width:frame.width,height:CGFloat.greatestFiniteMagnitude),
      options:[.usesLineFragmentOrigin],context:nil)
    return .init(x:frame.x,y:frame.y,width:min(frame.width,max(1,ceil(rect.width))),height:max(1,ceil(rect.height)))
  }
  static func frame(_ element: AgentElement) -> PageRect {
    element.kind == .nativeText ? fittingFrame(element.source,style:element.textStyle ?? .standard,in:element.frame) : element.frame
  }
  static func frame(_ element: SpatialElement) -> PageRect {
    let frame = PageRect(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height)
    return element.kind == .nativeText ? fittingFrame(element.source,style:element.textStyle,in:frame) : frame
  }

  static func attributed(_ text: String, style: NativeTextStyle, editing: Bool = false) -> NSAttributedString {
    let result = NSMutableAttributedString(string:text,attributes:attributes(style:style,format:style.format ?? .init(),editing:editing))
    for run in style.runs ?? [] where run.location >= 0 && run.length > 0 && run.location <= result.length-run.length {
      result.setAttributes(attributes(style:style,format:run.format,editing:editing),range:.init(location:run.location,length:run.length))
    }
    return result
  }
  static func attributes(style: NativeTextStyle, format: NativeTextFormat, editing: Bool = false) -> [NSAttributedString.Key:Any] {
    let weight = format.bold.map { $0 ? 0.9 : 0.3 } ?? style.weight
    let nativeWeight: NativeFont.Weight = switch weight {
    case ..<0.2: .light; case ..<0.4: .regular; case ..<0.6: .medium; case ..<0.8: .semibold; default: .bold
    }
    var font = format.fontName.flatMap { NativeFont(name:$0,size:style.fontSize) }
      ?? NativeFont.systemFont(ofSize:style.fontSize,weight:nativeWeight)
    #if os(iOS)
    var traits = font.fontDescriptor.symbolicTraits
    if format.bold == true { traits.insert(.traitBold) } else if format.bold == false { traits.remove(.traitBold) }
    if format.italic == true { traits.insert(.traitItalic) } else { traits.remove(.traitItalic) }
    if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor:descriptor,size:style.fontSize) }
    #else
    if format.bold == true { font = NSFontManager.shared.convert(font,toHaveTrait:.boldFontMask) }
    else if format.bold == false { font = NSFontManager.shared.convert(font,toNotHaveTrait:.boldFontMask) }
    if format.italic == true { font = NSFontManager.shared.convert(font,toHaveTrait:.italicFontMask) }
    #endif
    var result: [NSAttributedString.Key:Any] = [.font:font,
      .foregroundColor:NativeColor(red:style.red,green:style.green,blue:style.blue,alpha:style.alpha),formatKey:format]
    if let highlight = format.highlight { result[.backgroundColor] = NativeColor(red:highlight.red,green:highlight.green,blue:highlight.blue,alpha:1) }
    if let link = format.link, NativeTextFormat.isWebLink(link) {
      // An editor keeps link metadata, not a competing native link interaction.
      if editing { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
      else { result[.link] = URL(string:link) }
    }
    return result
  }
  static func format(from attributes: [NSAttributedString.Key:Any], base: NativeTextStyle, editing: Bool = false) -> NativeTextFormat {
    var format = attributes[formatKey] as? NativeTextFormat ?? base.format ?? .init()
    let expected = self.attributes(style:base,format:format)
    if let font = attributes[.font] as? NativeFont, let previous = expected[.font] as? NativeFont {
      if font.familyName != previous.familyName { format.fontName = font.fontName }
      #if os(iOS)
      let traits = font.fontDescriptor.symbolicTraits, oldTraits = previous.fontDescriptor.symbolicTraits
      if traits.contains(.traitBold) != oldTraits.contains(.traitBold) { format.bold = traits.contains(.traitBold) }
      if traits.contains(.traitItalic) != oldTraits.contains(.traitItalic) { format.italic = traits.contains(.traitItalic) }
      #else
      let traits = font.fontDescriptor.symbolicTraits, oldTraits = previous.fontDescriptor.symbolicTraits
      if traits.contains(.bold) != oldTraits.contains(.bold) { format.bold = traits.contains(.bold) }
      if traits.contains(.italic) != oldTraits.contains(.italic) { format.italic = traits.contains(.italic) }
      #endif
    }
    if !editing {
      let link = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
      format.link = link.flatMap { NativeTextFormat.isWebLink($0) ? $0 : nil }
    }
    if attributes[.backgroundColor] == nil { format.highlight = nil }
    return format
  }
  static func style(from text: NSAttributedString, base: NativeTextStyle, editing: Bool = false) -> NativeTextStyle {
    var result = base, runs: [NativeTextRun] = []
    text.enumerateAttributes(in:.init(location:0,length:text.length)) { attributes,range,_ in
      let format = format(from:attributes,base:base,editing:editing)
      if let last = runs.last, last.format == format, last.location+last.length == range.location {
        runs[runs.count-1].length += range.length
      } else { runs.append(.init(location:range.location,length:range.length,format:format)) }
    }
    result.runs = runs.isEmpty ? nil : runs
    return result
  }
}
