import NotebookCore
import SwiftUI

/// Both native readers demand the same addressed material. A directory slot
/// is not a blank sheet; only the deliberate trailing creation slot is blank.
private struct BlankFrameDemand: Hashable { let owner: ObjectIdentifier; let retry: UInt64 }

struct NotebookPageView: View {
  @Environment(NotebookAppModel.self) private var model
  let notebookID: UUID
  let index: Int
  let isCurrent: Bool
  let isInteractive: Bool
  let isVisible: Bool
  let onRenderReady: PageTurnReadiness
  let displayProjection: Double
  let refinesDetails: Bool
  var initialVisibleRegion: CGRect? = nil
  @State private var blankRetry: UInt64 = 0
  #if os(iOS)
  @State private var blankFrame: PageTurnFrame?
  #endif

  var body: some View {
    if index < 0 || index >= model.notebookPageCount(notebookID) {
      BlankPageSurface(fallbackSize: model.notebookPageSize)
        .task(id: BlankFrameDemand(owner: ObjectIdentifier(onRenderReady), retry: blankRetry)) {
          #if os(iOS)
          do {
            let frame: PageTurnFrame
            if let blankFrame { frame = blankFrame }
            else {
              let size = CGSize(width: model.notebookPageSize.width, height: model.notebookPageSize.height)
              let canvas = try await SceneRasterCompositor.create(size: size, scale: 2, resources: .shared)
              try await canvas.drawView(GridPaperView(), size: size, in: CGRect(origin: .zero, size: size))
              let pixels = try await canvas.finishImage()
              frame = try await PageTurnFrame.compose(size: size, scale: 2,
                images: [.init(image: pixels.image, frame: CGRect(origin: .zero, size: size))], retaining: [pixels])
              blankFrame = frame
            }
            try Task.checkCancellation()
            onRenderReady.setFrameProvider { _ in frame }
            onRenderReady(index == model.notebookPageCount(notebookID))
          } catch is CancellationError { }
          catch { onRenderReady.failed(.init(message: "Не удалось подготовить чистый лист", retry: { blankFrame = nil; blankRetry &+= 1 })) }
          #else
          onRenderReady(index == model.notebookPageCount(notebookID))
          #endif
        }
    } else if let page = model.notebookPage(at: index, in: notebookID) {
      acceptedPage(page)
        #if os(iOS)
        .onAppear { blankFrame = nil }
        #endif
    } else {
      BlankPageSurface(fallbackSize: model.notebookPageSize)
        .overlay { ProgressView().allowsHitTesting(false) }
        .onAppear { onRenderReady(false) }
        .task { await model.prepareNotebookPage(at: index, in: notebookID) }
        .accessibilityLabel("Загружается лист \(index + 1)")
    }
  }

  @ViewBuilder
  private func acceptedPage(_ page: PageDocument) -> some View {
    if onRenderReady.acceptNotebookPage(page.id, from: model.notebookPagePreparation) {
      PageSurface(page: page, isCurrent: isCurrent, isInteractive: isInteractive,
        isVisible: isVisible, onRenderReady: onRenderReady, displayProjection: displayProjection,
        refinesDetails: refinesDetails, initialVisibleRegion: initialVisibleRegion)
    } else {
      // A native notebook leaf never creates an autonomous program. Its page
      // owner publishes admission once the bound controller/address is ready.
      BlankPageSurface(fallbackSize: page.size)
        .overlay { ProgressView().allowsHitTesting(false) }
        .onAppear { onRenderReady(false) }
        .accessibilityLabel("Загружается лист \(index + 1)")
    }
  }
}

struct PageSurface: View {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.displayScale) private var displayScale

  let page: PageDocument
  let isCurrent: Bool
  let isInteractive: Bool
  let isVisible: Bool
  let onRenderReady: PageTurnReadiness
  /// Maximum physical projection of the already owned paper while it opens.
  /// A standalone page/thumbnail is laid out directly and needs no outer scale.
  var displayProjection: Double = 1
  var refinesDetails = true
  var initialVisibleRegion: CGRect? = nil

  @State private var visibleRegion: CGRect?
  #if os(iOS)
  @State private var graphicCoverageOwner=UUID()
  @State private var materialOwner = PageTurnMaterialOwner()
  @State private var materialScale = 2.0
  @State private var orderedMaterialIDs: Set<String> = []
  #endif
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
      let graphicDisplay=model.pageGraphicDisplay(page,in:visibleRegion ?? initialVisibleRegion)
      let orderedInput=model.pageOrderedInk(page,display:graphicDisplay)
      ZStack(alignment: .topLeading) {
        GridPaperView()
        if scale > 0 {
          Group {
            #if os(iOS)
            agentOverlay(renderingScale:scale * displayProjection,display:graphicDisplay)
              .mask {
                if liveElementEraser.isActive {
                  NotebookLiveElementEraserMask(presentation:liveElementEraser)
                    .allowsHitTesting(false)
                } else { Color.white }
              }
            #else
            agentOverlay(renderingScale:scale * displayProjection,display:graphicDisplay)
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
            orderedInput:orderedInput,
            isInputEnabled: isVisible && isInteractive,
            isVisible: isVisible,
            isCurrent: isCurrent,
            pageReadiness: onRenderReady,
            refinesDetails: refinesDetails,
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
              model.canonicalPageInkInstalled(receipt,elementSource:page.elementSourceIdentity,input:orderedInput)
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
            isCurrent:isCurrent,pageReadiness:onRenderReady,refinesDetails:refinesDetails) { receipt in
            model.canonicalPageInkInstalled(receipt,elementSource:page.elementSourceIdentity,input:orderedInput)
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
      #if os(iOS)
      .onChange(of: max(0.1, scale * displayProjection * displayScale), initial: true) { _, density in
        materialScale = density; publishReadiness()
      }
      .onChange(of: orderedInput, initial: true) { _, input in
        orderedMaterialIDs = Set(input.candidates.map(\.id)); publishReadiness()
      }
      .onChange(of:Set(graphicDisplay.elements.map(\.id)),initial:true) { _,visible in
        publishGraphicCoverage(visible)
      }
      .onChange(of:isCurrent && isInteractive && isVisible,initial:true) { _,_ in
        publishGraphicCoverage(Set(graphicDisplay.elements.map(\.id)))
      }
      #endif
    }
    #if os(iOS)
    .onAppear { publishReadiness() }
    .onDisappear {
      model.selectedGraphicHosts.removePageCoverage(page.id,owner:graphicCoverageOwner)
      materialOwner.retire()
    }
    #endif
    .onChange(of:ObjectIdentifier(onRenderReady),initial:true) { _, _ in
      publishReadiness()
    }
    .onChange(of: page.elementSourceIdentity) { _, _ in
      publishReadiness()
    }
    .onChange(of: isCurrent) { _, _ in publishReadiness() }
  }

  private func publishReadiness() {
    #if os(iOS)
    materialOwner.prepare(page: page, erasures: model.pagePresentationErasures(page),
      ordered: orderedMaterialIDs, scale: materialScale, onReady: {
        publishReadiness()
      }, onFailure: onRenderReady.captureFailed)
    materialOwner.prepareStaticSlots(readiness: onRenderReady,
      onReady: { publishReadiness() }, onFailure: onRenderReady.captureFailed)
    materialOwner.preparePassiveFrame(readiness: onRenderReady, enabled: !isCurrent)
    onRenderReady.setFrameProvider { [page, weak owner = materialOwner, weak receipt = onRenderReady] priority in
      guard let owner, let receipt else { throw SceneRenderError.snapshotPending("retired_page_material") }
      return try await owner.acquire(page: page, readiness: receipt, priority: priority)
    }
    onRenderReady(readiness.isReady(page),
      capturable: materialOwner.isCapturable(readiness: onRenderReady) && onRenderReady.inkFrameIsReady?() == true,
      paperReady: readiness.paperIsReady(page))
    #else
    onRenderReady(readiness.isReady(page))
    #endif
  }

  #if os(iOS)
  private func publishGraphicCoverage(_ visible:Set<String>) {
    guard isCurrent,isInteractive,isVisible,model.presence?.notebookPageID == page.id else {
      model.selectedGraphicHosts.removePageCoverage(page.id,owner:graphicCoverageOwner)
      return
    }
    model.selectedGraphicHosts.publishPageCoverage(page.id,owner:graphicCoverageOwner,visible:visible)
  }
  #endif

  private func agentOverlay(renderingScale:Double,display:NotebookPageGraphicDisplay) -> some View {
    AgentOverlayView(page:page,renderingScale:renderingScale,preparedDisplay:display,
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
      },visibleRegion:visibleRegion ?? initialVisibleRegion,pageTurnActivity:onRenderReady.activity,
      rasterPreparation:onRenderReady.rasterContext ?? .init(owner:rasterPreparation,pageIndex:0),
      preparations:onRenderReady.activity == nil ? nil : onRenderReady.agentPreparations,
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
