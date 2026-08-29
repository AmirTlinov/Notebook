import PencilKit
import SwiftUI
import TetradCore

struct PencilDrawingView: View {
  let page: PageDocument

  var body: some View {
    if let drawing = try? PKDrawing(data: page.drawingData),
       !page.drawingData.isEmpty {
      #if os(iOS)
        Image(
          uiImage: drawing.image(
            from: CGRect(
              x: 0,
              y: 0,
              width: page.size.width,
              height: page.size.height
            ),
            scale: 2
          )
        )
        .resizable()
      #else
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
      #endif
    }
  }
}
