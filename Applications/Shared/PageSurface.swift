import NotebookCore
import SwiftUI

struct PageSurface: View {
  @Environment(NotebookAppModel.self) private var model

  let page: PageDocument
  let isCurrent: Bool
  let isInteractive: Bool
  let isVisible: Bool
  let onRenderReady: PageTurnReadiness
  /// Maximum physical projection of the already owned paper while it opens.
  /// A standalone page/thumbnail is laid out directly and needs no outer scale.
  var displayProjection: Double = 1

  @State private var visibleRegion: CGRect?
  @State private var inkIsReady = false
  @State private var readyOverlay: ObjectIdentifier?

  private var overlayIsReady: Bool { readyOverlay == page.elementSourceIdentity }

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
        if scale > 0 {
          AgentOverlayView(
            page:page,
            renderingScale: scale * displayProjection,
            allowsInteraction: isVisible && isCurrent,
            inputEnabled: isVisible && isInteractive,
            onRenderReady: { ready in
              if ready { readyOverlay = page.elementSourceIdentity }
              else if readyOverlay == page.elementSourceIdentity { readyOverlay = nil }
              publishReadiness(ink: inkIsReady, overlay: overlayIsReady)
            },
            onState: { elementID, state in
              guard isVisible, isCurrent, model.activePage?.id == page.id else { return false }
              return model.commitElementState(pageID: page.id, elementID: elementID, state: state)
            }, visibleRegion: visibleRegion
          )
          .opacity(isVisible ? 1 : 0)
          .allowsHitTesting(isVisible && isInteractive)
        }
        #if os(iOS)
          PencilCanvasView(
            pageID: page.id,
            drawingData: page.drawingData,
            suppressedInkIDs: model.pageSuppressedInkIDs(page),
            isInputEnabled: isInteractive,
            penStyle: model.activePenStyle,
            eraserStyle: model.eraserStyle,
            drawingTool: model.drawingTool,
            inputGate: model.inputGate,
            reserveAction: model.reserveDrawingAction,
            releaseAction: { model.releaseDrawingReservation(pageID: $0, stamp: $1) },
            acceptAction: { action, pageID, stamp, fit in
              model.acceptDrawingAction(action, pageID: pageID, stamp: stamp, quickShape: fit)
            },
            onRenderReady: { ready in
              inkIsReady = ready
              publishReadiness(ink: ready, overlay: overlayIsReady)
            }, resolveQuickShape: { fit, scale in
              fit.binding(in:page.graphicGraph(),surface:.page(page.id),tolerance:18/scale,
                erasures:model.elementErasures(on:.page(page.id)),appearance: { id,graphic,layout,size,cuts in
                  model.elementErasureCache.appearance(surface:.page(page.id),id:id,graphic:graphic,layout:layout,size:size,erasures:cuts)
                })
            }, onWorkingGraphic: model.updateWorkingGraphic,
            eraserTargets: { model.eraserTargets(pageID: page.id) },
            onElementErasing: model.updateElementErasing
          )
        #else
          MacPageInkView(page: page, isInteractive: isVisible && isInteractive) { ready in
            inkIsReady = ready
            publishReadiness(ink: ready, overlay: overlayIsReady)
          }.id(page.id)
          if isVisible,isCurrent,let reference=model.selectionSession.editingElement,
            case .page(let owner,_) = reference,owner == page.id {
            let graphic=model.graphicLayout(reference)?.frame
            let group=model.groupManipulationGeometry(reference)?.bounds
            if let frame=graphic.map({ CGRect(x:$0.x,y:$0.y,width:$0.width,height:$0.height) }) ?? group {
              MacElementControls(reference:reference,frame:frame,scale:1)
            }
          }
        #endif

      }
      .frame(width: page.size.width, height: page.size.height)
      .background(PagePresentationView(page: page, isCurrent: isCurrent,
        isVisible: isVisible, isReady: inkIsReady && overlayIsReady,
        activity: onRenderReady.activity, onVisibleRegion: { visibleRegion = $0 }).allowsHitTesting(false))
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
    .onChange(of: page.elementSourceIdentity) { _, _ in
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
