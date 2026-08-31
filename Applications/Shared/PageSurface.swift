import SwiftUI
import NotebookCore

#if os(iOS)
  import PencilKit
  import UIKit
#endif

struct PageSurface: View {
  @Environment(NotebookAppModel.self) private var model

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
            pencilInputGate: model.pencilInputGate,
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
      .clipShape(
        RoundedRectangle(
          cornerRadius: NotebookGeometry.cornerRadius,
          style: .continuous
        )
      )
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

/// A neighbouring sheet is a readout, not another writing surface. It keeps
/// the interactive Pencil owner singular while making the next sheet ready
/// before the fingers begin to move it onscreen.
struct PageReadoutSurface: View {
  let page: PageDocument?
  let fallbackSize: PageSize

  var body: some View {
    GeometryReader { geometry in
      let pageSize = page?.size ?? fallbackSize
      let scale = min(
        geometry.size.width / pageSize.width,
        geometry.size.height / pageSize.height
      )
      let renderedSize = CGSize(
        width: pageSize.width * scale,
        height: pageSize.height * scale
      )
      ZStack(alignment: .topLeading) {
        GridPaperView()
        if let page {
          #if os(iOS)
            PencilDrawingReadout(
              drawingData: page.drawingData,
              pageSize: page.size
            )
          #else
            PencilDrawingView(page: page)
          #endif
          AgentOverlayView(elements: page.elements) { _, _ in }
          .allowsHitTesting(false)
        }
      }
      .frame(width: pageSize.width, height: pageSize.height)
      .clipShape(
        RoundedRectangle(
          cornerRadius: NotebookGeometry.cornerRadius,
          style: .continuous
        )
      )
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
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

#if os(iOS)
private struct PencilDrawingReadout: UIViewRepresentable {
  let drawingData: Data
  let pageSize: PageSize

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> UIImageView {
    let view = UIImageView()
    view.backgroundColor = .clear
    view.isOpaque = false
    view.contentMode = .scaleToFill
    update(view, coordinator: context.coordinator)
    return view
  }

  func updateUIView(_ view: UIImageView, context: Context) {
    update(view, coordinator: context.coordinator)
  }

  private func update(_ view: UIImageView, coordinator: Coordinator) {
    let key = DrawingKey(data: drawingData, size: pageSize)
    guard coordinator.key != key else { return }
    coordinator.key = key
    guard !drawingData.isEmpty,
      let drawing = try? PKDrawing(data: drawingData)
    else {
      view.image = nil
      return
    }
    view.image = drawing.image(
      from: CGRect(
        x: 0,
        y: 0,
        width: pageSize.width,
        height: pageSize.height
      ),
      scale: min(2, max(1, view.traitCollection.displayScale))
    )
  }

  final class Coordinator {
    var key: DrawingKey?
  }

  struct DrawingKey: Equatable {
    let data: Data
    let size: PageSize
  }
}
#endif
