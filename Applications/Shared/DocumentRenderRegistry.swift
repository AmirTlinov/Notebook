import Foundation
import NotebookCore
import Observation

struct DocumentBlockRegion: Equatable {
  let id: String
  let pageIndex: Int
  let frame: PageRect
}

/// The actual WebKit layout names the block fragments on each physical sheet.
@MainActor
@Observable
final class DocumentRenderRegistry {
  static let shared = DocumentRenderRegistry()
  struct Entry {
    let token: String
    let pageIndex: Int
    let regions: [DocumentBlockRegion]
    let diagnostics: [RenderDiagnostic]
  }
  private var entries: [UUID: [Entry]] = [:]

  func entry(document: DocumentDocument, state: DocumentStateJournal, pageIndex: Int) -> Entry? {
    let token = "\(document.contentStamp.revision)|\(state.stamp.revision)"
    return entries[document.id]?.last { $0.token.hasPrefix(token) && $0.pageIndex == pageIndex }
  }

  func publish(documentID: UUID, token: String, receipt: NSDictionary, geometry: WorkspaceItemGeometry) {
    let width = (receipt["width"] as? NSNumber)?.doubleValue ?? geometry.width
    let height = (receipt["height"] as? NSNumber)?.doubleValue ?? geometry.height
    guard width > 0, height > 0, let pageIndex = (receipt["pageIndex"] as? NSNumber)?.intValue else { return }
    let regions = (receipt["regions"] as? [[String: Any]] ?? []).compactMap { value -> DocumentBlockRegion? in
      guard let id = value["id"] as? String, let page = value["pageIndex"] as? Int,
        let x = value["x"] as? Double, let y = value["y"] as? Double,
        let w = value["width"] as? Double, let h = value["height"] as? Double, w > 0, h > 0 else { return nil }
      return .init(id: id, pageIndex: page, frame: .init(x:x * geometry.width / width,y:y * geometry.height / height,
        width:w * geometry.width / width,height:h * geometry.height / height))
    }
    let diagnostics = (receipt["diagnostics"] as? [[String: String]] ?? []).map { RenderDiagnostic(kind: $0["kind"] ?? "render_error", elementID: $0["blockID"], message: $0["message"] ?? "") }
    var values = entries[documentID] ?? []
    values.removeAll { $0.token == token && $0.pageIndex == pageIndex }
    values.append(.init(token: token, pageIndex: pageIndex, regions: regions, diagnostics: diagnostics))
    entries[documentID] = Array(values.suffix(8))
  }
}
