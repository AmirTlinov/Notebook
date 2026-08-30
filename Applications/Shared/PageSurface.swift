import SwiftUI
import TetradCore

struct PageSurface: View {
  @Environment(TetradAppModel.self) private var model

  let page: PageDocument
  let isInteractive: Bool
  let isVisible: Bool

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
        #if os(iOS)
          PencilCanvasView(
            pageID: page.id,
            drawingData: page.drawingData,
            isInputEnabled: isInteractive,
            penStyle: model.penStyle,
            eraserStyle: model.eraserStyle,
            drawingTool: model.drawingTool,
            pageInputGate: model.pageInputGate,
            reserveAction: model.reserveDrawingAction,
            commitAction: { data, previousData, pageID, stamp in
              model.commitDrawingAction(
                data,
                replacing: previousData,
                pageID: pageID,
                stamp: stamp
              )
            }
          )
        #else
          PencilDrawingView(page: page)
            .allowsHitTesting(false)
        #endif
        if isVisible {
          AgentOverlayView(elements: page.elements) { elementID, state in
            model.commitElementState(elementID: elementID, state: state)
          }
          .allowsHitTesting(isInteractive)
        }
      }
      .frame(width: page.size.width, height: page.size.height)
      .scaleEffect(scale, anchor: .topLeading)
      .frame(
        width: renderedSize.width,
        height: renderedSize.height,
        alignment: .topLeading
      )
      .frame(
        width: geometry.size.width,
        height: geometry.size.height,
        alignment: .center
      )
      .clipped()
    }
  }
}
