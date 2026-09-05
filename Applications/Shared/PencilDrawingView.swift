#if os(macOS)
import SwiftUI
import NotebookCore

struct PencilDrawingView: View {
  let page: PageDocument

  @State private var rendered: CGImage?
  @State private var renderedPageID: UUID?
  var body: some View {
    Group {
      if let rendered, renderedPageID == page.id {
        Image(nsImage: NSImage(cgImage: rendered, size: .init(width: page.size.width, height: page.size.height))).resizable()
      }
    }
    .task(id: "\(page.id)-\(page.drawingStamp.revision)") {
      await PageInkRasterCache.shared.prepare(page)
      guard !Task.isCancelled else { return }
      rendered = PageInkRasterCache.shared.image(for: page)
      renderedPageID = page.id
    }
  }
}
#endif
