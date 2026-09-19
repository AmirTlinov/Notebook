import NotebookCore
import UIKit
import UniformTypeIdentifiers

/// The system clipboard carries a native text fragment plus plain text for
/// other apps. Paste still enters Notebook's ordinary atomic fragment writer.
@MainActor enum NotebookTextObjectClipboard {
  private static let type = "com.amirtlinov.notebook.native-text"
  static func copy(_ target: NotebookNativeTextTarget) {
    let element = AgentElement(id:"clipboard",kind:.nativeText,
      frame:.init(x:0,y:0,width:target.frame.width,height:target.frame.height),source:target.source,html:target.source,textStyle:target.style)
    var item: [String:Any] = [UTType.utf8PlainText.identifier:target.source]
    if let data = try? JSONEncoder().encode(element) { item[type] = data }
    UIPasteboard.general.items = [item]
  }
  static func paste(nextTo target: NotebookNativeTextTarget, model: NotebookAppModel) async -> Bool {
    guard let text = UIPasteboard.general.string, !text.isEmpty, text.utf8.count <= 65_536 else { return false }
    let copied = UIPasteboard.general.data(forPasteboardType:type).flatMap { data -> AgentElement? in
      guard data.count <= 262_144, let element = try? JSONDecoder().decode(AgentElement.self,from:data),
        element.kind == .nativeText, element.source == text,
        element.frame.width.isFinite, (1...1_000_000).contains(element.frame.width),
        let style = element.textStyle, (3...5760).contains(style.fontSize),
        [style.weight,style.red,style.green,style.blue,style.alpha].allSatisfy({ (0...1).contains($0) }) else { return nil }
      return element
    }
    let style = copied?.kind == .nativeText && copied?.source == text ? copied?.textStyle ?? target.style : target.style
    let width = min(copied?.frame.width ?? target.frame.width,target.address.bounds?.width ?? .greatestFiniteMagnitude)
    let fitted = NotebookTextTypography.fittingFrame(text,style:style,in:.init(x:0,y:0,width:width,height:target.frame.height))
    let size = SpatialPoint(x:fitted.width,y:fitted.height)
    let element = AgentElement(id:"text-"+UUID().uuidString.lowercased(),kind:.nativeText,
      frame:.init(x:0,y:0,width:size.x,height:size.y),source:text,html:text,textStyle:style)
    let x = min(target.frame.x+24,max(0,(target.address.bounds?.maxX ?? .greatestFiniteMagnitude)-size.x))
    let y = min(target.frame.y+target.frame.height+12,max(0,(target.address.bounds?.maxY ?? .greatestFiniteMagnitude)-size.y))
    let destination = NotebookPasteDestination(target:target.address.target,title:"Текст",
      center:.init(x:x+size.x/2,y:y+size.y/2),availableSize:size,worldOrigin:target.address.worldOrigin)
    return await model.insertClipboardFragment(.init(elements:[element],size:size),at:destination)
  }
}
