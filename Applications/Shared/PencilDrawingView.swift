#if os(macOS)
import PencilKit
import SwiftUI
import NotebookCore

struct PencilDrawingView: View {
  let page: PageDocument

  var body: some View {
    if !page.drawingData.isEmpty,
       let drawing = try? PKDrawing(data: page.drawingData) {
      Image(
        nsImage: PaperInkRenderer.image(
          from: drawing,
          bounds: CGRect(
            x: 0,
            y: 0,
            width: page.size.width,
            height: page.size.height
          ),
          scale: 2
        )
      )
      .resizable()
    }
  }
}
#endif
