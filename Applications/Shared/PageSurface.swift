import NotebookCore
import SwiftUI

struct PageSurface: View {
  @Environment(NotebookAppModel.self) private var model

  let page: PageDocument
  let isInteractive: Bool
  let isVisible: Bool
  let onRenderReady: PageTurnReadiness

  @State private var inkIsReady = false
  @State private var overlayIsReady = false

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
            isInputEnabled: isInteractive && !model.isElementEditingEnabled,
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
            },
            onRenderReady: { ready in
              inkIsReady = ready
              publishReadiness(ink: ready, overlay: overlayIsReady)
            }
          )
        #else
          PencilDrawingView(page: page)
            .allowsHitTesting(false)
            .onAppear {
              inkIsReady = true
              publishReadiness(ink: true, overlay: overlayIsReady)
            }
        #endif
        AgentOverlayView(
          elements: page.elements,
          isElementEditingEnabled: model.isElementEditingEnabled && isInteractive,
          onMove: { elementID, translation in
            _ = model.movePageElement(
              pageID: page.id,
              elementID: elementID,
              by: SpatialPoint(
                x: translation.width,
                y: translation.height
              )
            )
          },
          onDelete: { elementID in
            _ = model.removePageElement(
              pageID: page.id,
              elementID: elementID
            )
          },
          onRenderReady: { ready in
            overlayIsReady = ready
            publishReadiness(ink: inkIsReady, overlay: ready)
          },
          onState: { elementID, state in
            model.commitElementState(elementID: elementID, state: state)
          }
        )
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible && isInteractive)
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
    .onAppear {
      publishReadiness(ink: inkIsReady, overlay: overlayIsReady)
    }
  }

  private func publishReadiness(ink: Bool, overlay: Bool) {
    onRenderReady(ink && overlay)
  }
}

/// The provisional sheet after the last persisted notebook page.
struct BlankPageSurface: View {
  let fallbackSize: PageSize

  var body: some View {
    GeometryReader { geometry in
      let pageSize = fallbackSize
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
