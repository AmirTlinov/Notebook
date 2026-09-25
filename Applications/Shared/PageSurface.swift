import NotebookCore
import SwiftUI

/// Both native readers demand the same addressed material. A directory slot
/// is not a blank sheet; only the deliberate trailing creation slot is blank.
struct NotebookPageView: View {
  @Environment(NotebookAppModel.self) private var model
  let notebookID: UUID
  let index: Int
  let isCurrent: Bool
  let isInteractive: Bool
  let isVisible: Bool
  let onRenderReady: PageTurnReadiness
  let displayProjection: Double

  var body: some View {
    if index < 0 || index >= model.notebookPageCount(notebookID) {
      BlankPageSurface(fallbackSize: model.notebookPageSize)
        .onAppear { onRenderReady(index == model.notebookPageCount(notebookID)) }
    } else if let page = model.notebookPage(at: index, in: notebookID) {
      PageSurface(page: page, isCurrent: isCurrent, isInteractive: isInteractive,
        isVisible: isVisible, onRenderReady: onRenderReady, displayProjection: displayProjection)
    } else {
      BlankPageSurface(fallbackSize: model.notebookPageSize)
        .overlay { ProgressView().allowsHitTesting(false) }
        .onAppear { onRenderReady(false) }
        .task { await model.prepareNotebookPage(at: index, in: notebookID) }
        .accessibilityLabel("Загружается лист \(index + 1)")
    }
  }
}

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
  @State private var rasterPreparation = PageRasterPreparation()
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
                if liveElementEraser.isActive {
                  NotebookLiveElementEraserMask(presentation:liveElementEraser)
                    .allowsHitTesting(false)
                } else { Color.white }
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
            isInputEnabled: isVisible && isInteractive,
            isVisible: isVisible,
            isCurrent: isCurrent,
            pageReadiness: onRenderReady,
            refinesDetails: model.presencePhase == .settled,
            penStyle: model.activePenStyle,
            eraserStyle: model.eraserStyle,
            drawingTool: model.drawingTool,
            inputGate: model.inputGate,
            publication: model.pageInkPublication,
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
          MacPageInkView(page: page, isInteractive: isVisible && isInteractive, isVisible:isVisible,
            isCurrent:isCurrent,pageReadiness:onRenderReady,refinesDetails:model.presencePhase == .settled) { receipt in
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
        readiness.recordGraphics(ready,page:page);publishReadiness()
      },onErasurePresentation: { receipt in
        #if os(iOS)
        liveElementEraser.presented(receipt)
        #endif
      },onState:{ elementID,state,completion in
        // Admission belongs to the live program; a turn cannot cancel a
        // snapshot already accepted before this page lost presentation.
        model.commitElementState(pageID:page.id,elementID:elementID,state:state,onCommitted:completion)
      },visibleRegion:visibleRegion,pageTurnActivity:onRenderReady.activity,
      rasterPreparation:onRenderReady.rasterContext ?? .init(owner:rasterPreparation,pageIndex:0),
      onFailure:onRenderReady.failed)
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
