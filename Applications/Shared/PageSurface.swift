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
  @State private var readiness=PageSurfaceReadiness()
  #if os(iOS)
  @State private var liveElementEraser = NotebookLiveElementEraserPresentation()
  #endif


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
          Group {
            #if os(iOS)
            agentOverlay(renderingScale:scale * displayProjection)
              .mask {
                ZStack {
                  NotebookLiveElementEraserMask(presentation:liveElementEraser)
                    .allowsHitTesting(false)
                  if !liveElementEraser.isActive { Color.white }
                }
              }
            #else
            agentOverlay(renderingScale:scale * displayProjection)
            #endif
          }
          .opacity(isVisible ? 1 : 0)
          .allowsHitTesting(isVisible && isInteractive)
        }
        #if os(iOS)
          PencilCanvasView(
            pageID: page.id,
            source: page.inkSource,
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
            onRenderReady: { receipt in
              readiness.recordInk(receipt);publishReadiness()
            }, resolveQuickShape: { fit, scale in
              fit.binding(in:model.graphicGraph(page:model.pages[page.id] ?? page),surface:.page(page.id),tolerance:18/scale,
                erasures:model.elementErasures(on:.page(page.id)),appearance: { id,graphic,layout,size,cuts in
                  model.elementErasureCache.appearance(surface:.page(page.id),id:id,graphic:graphic,layout:layout,size:size,erasures:cuts)
                })
            }, onWorkingGraphic: model.updateWorkingGraphic,
            pageEraserSource: { model.pageEraserSource(pageID: page.id) },
            onEraserFailure: { model.showCue($0.localizedDescription) },
            onLiveElementErasing: liveElementEraser.display,
            onElementErasing: model.updateElementErasing
          )
        #else
          MacPageInkView(page: page, isInteractive: isVisible && isInteractive) { receipt in
            readiness.recordInk(receipt);publishReadiness()
          }.id(page.id)
        #endif

      }
      .frame(width: page.size.width, height: page.size.height)
      .background(PagePresentationView(page: page, isCurrent: isCurrent,
        isVisible: isVisible, readiness:readiness,
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
    .onChange(of:ObjectIdentifier(onRenderReady),initial:true) { _, _ in
      publishReadiness()
    }
    .onChange(of: page.elementSourceIdentity) { _, _ in
      publishReadiness()
    }
  }

  private func publishReadiness() {
    onRenderReady(readiness.isReady(page))
  }

  private func agentOverlay(renderingScale:Double) -> some View {
    AgentOverlayView(page:page,renderingScale:renderingScale,
      allowsInteraction:isVisible && isCurrent,inputEnabled:isVisible && isInteractive,
      onRenderReady:{ ready in
        #if os(iOS)
        if ready { liveElementEraser.presented(model.elementErasures(on:.page(page.id))) }
        #endif
        readiness.recordGraphics(ready,page:page);publishReadiness()
      },onState:{ elementID,state in
        guard isVisible,isCurrent,model.activePage?.id == page.id else { return false }
        return model.commitElementState(pageID:page.id,elementID:elementID,state:state)
      },visibleRegion:visibleRegion,pageTurnActivity:onRenderReady.activity)
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
