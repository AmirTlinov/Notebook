import NotebookCore
import SwiftUI

struct PageSurface: View {
  @Environment(NotebookAppModel.self) private var model

  let page: PageDocument
  let isInteractive: Bool
  let isVisible: Bool
  let onRenderReady: PageTurnReadiness

  @State private var inkIsReady = false
  @State private var readyOverlay: [AgentElement]?

  private var overlayIsReady: Bool { readyOverlay == page.elements }

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
            isInputEnabled: isInteractive && !model.isElementEditingEnabled && !model.isPointing,
            penStyle: model.penStyle,
            eraserStyle: model.eraserStyle,
            drawingTool: model.drawingTool,
            inputGate: model.inputGate,
            reserveAction: model.reserveDrawingAction,
            releaseAction: { model.releaseDrawingReservation(pageID: $0, stamp: $1) },
            acceptAction: { action, pageID, stamp in
              model.acceptDrawingAction(action, pageID: pageID, stamp: stamp)
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
          pageID: page.id,
          elements: page.elements,
          isElementEditingEnabled: model.isElementEditingEnabled && isInteractive,
          allowsInteraction: isVisible && isInteractive,
          onRenderReady: { ready in
            if ready { readyOverlay = page.elements }
            else if readyOverlay == page.elements { readyOverlay = nil }
            publishReadiness(ink: inkIsReady, overlay: overlayIsReady)
          },
          onState: { elementID, state in
            guard isVisible, isInteractive, model.activePage?.id == page.id else { return }
            model.commitElementState(pageID: page.id, elementID: elementID, state: state)
          }
        )
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible && isInteractive)
      }
      .frame(width: page.size.width, height: page.size.height)
      .clipShape(
        RoundedRectangle(
          cornerRadius: WorkspaceItemGeometry.notebook.cornerRadius,
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
    .onChange(of: page.elements) { _, _ in
      publishReadiness(ink: inkIsReady, overlay: overlayIsReady)
    }
  }

  private func publishReadiness(ink: Bool, overlay: Bool) {
    onRenderReady(ink && overlay)
    model.pagePresented(page,ready:ink && overlay)
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
          cornerRadius: WorkspaceItemGeometry.notebook.cornerRadius,
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
