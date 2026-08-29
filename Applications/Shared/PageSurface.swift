import SwiftUI
import TetradCore

struct PageSurface: View {
  @Environment(TetradAppModel.self) private var model

  let page: PageDocument
  let acceptsPencil: Bool

  var body: some View {
    GeometryReader { geometry in
      let scale = min(
        geometry.size.width / page.size.width,
        geometry.size.height / page.size.height
      )
      let renderedSize = CGSize(
        width: page.size.width * scale,
        height: page.size.height * scale
      )
      ZStack(alignment: .topLeading) {
        GridPaperView()
        if acceptsPencil {
          #if os(iOS)
            PencilCanvasView(
              pageID: page.id,
              drawingData: page.drawingData,
              penStyle: model.penStyle,
              onChange: model.replaceDrawing
            )
          #endif
        } else {
          PencilDrawingView(page: page)
            .allowsHitTesting(false)
        }
        AgentOverlayView(elements: page.elements) { elementID, state in
          model.commitElementState(elementID: elementID, state: state)
        }
      }
      .frame(width: page.size.width, height: page.size.height)
      .scaleEffect(scale, anchor: .topLeading)
      .frame(width: renderedSize.width, height: renderedSize.height)
      .position(
        x: geometry.size.width / 2,
        y: geometry.size.height / 2
      )
      .clipped()
    }
  }
}
