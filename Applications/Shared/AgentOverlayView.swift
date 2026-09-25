import NotebookCore
import SwiftUI

struct AgentOverlayView: View {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.displayScale) private var displayScale

  let page:PageDocument
  let renderingScale: Double
  private var pageID:UUID { page.id }
  private var pageSize:PageSize { page.size }
  let allowsInteraction: Bool
  let inputEnabled: Bool
  let onRenderReady: (Bool) -> Void
  var onErasurePresentation: (PageElementErasurePresentation) -> Void = { _ in }
  let onState: (String, JSONValue, NotebookProgramStateCompletion) -> Bool
  var visibleRegion: CGRect? = nil
  var pageTurnActivity: PageTurnActivity? = nil
  var rasterPreparation: PageRasterPreparation.Context? = nil
  var onFailure: (PageTurnPreparationFailure) -> Void = { _ in }

  @State private var readiness = AgentOverlayReadiness()
  @State private var readinessID = UUID()

  private var display:NotebookPageGraphicDisplay { model.pageGraphicDisplay(page,in:visibleRegion) }

  private var paintedErasures: [String: [InkElementErasure]] {
    #if os(iOS)
    model.pagePresentationErasures(page)
    #else
    model.elementErasures(on: .page(pageID))
    #endif
  }

  private func capturePolicy(for element: AgentElement, presentation:NotebookElementPresentation) -> AgentSnapshotPolicy {
    let body=CGRect(origin:.zero,size:presentation.bodySize)
    let region=CGRect(x:0,y:0,width:pageSize.width,height:pageSize.height)
      .applying(presentation.placement.transform.inverted()).intersection(body)
    let density=renderingScale * displayScale * presentation.maximumScale
    if region == body { return .exact(scale:density) }
    return .region(.init(x:region.minX,y:region.minY,width:region.width,height:region.height),scale:density)
  }

  var body: some View {
    let display=display,visible=display.elements,graph=display.graph
    let erasures = paintedErasures
    let presentations=Dictionary(uniqueKeysWithValues:visible.compactMap { element -> (String,NotebookElementPresentation)? in
      guard let value=model.elementPresentation(.page(pageID:pageID,elementID:element.id),graph:graph) else { return nil }
      return (element.id,value)
    })
    let runningPrograms=Set(visible.filter { element in
      allowsInteraction && element.kind == .web && presentations[element.id].map { value in
        visibleRegion.map { $0.intersects(value.bounds) } ?? true
      } == true
    }.map(\.id))
    // Observe completion in this body, not only in the deferred ForEach builder.
    let appearances = Dictionary(uniqueKeysWithValues: visible.compactMap { element -> (String, NotebookElementAppearance)? in
      let layout = display.layouts[element.id]
      let frame = layout?.frame ?? element.frame
      guard let value = model.elementErasureCache.appearance(surface:.page(pageID),id:element.id,
        graphic:graph.nodes[element.id]?.graphic,layout:layout,size:presentations[element.id]?.bodySize ?? .init(width:frame.width,height:frame.height),
        erasures:erasures[element.id] ?? [],prepares:!model.isElementErasing(element.id,on:.page(pageID))) else { return nil }
      return (element.id,value)
    })
    ZStack(alignment: .topLeading) {
      ForEach(visible) { element in
        let reference = EditableElementReference.page(
          pageID: pageID,
          elementID: element.id
        )
        let interactiveReference = InteractiveElementReference.page(pageID: pageID, elementID: element.id)
        let layout = display.layouts[element.id]
        let presentation=presentations[element.id]
        let frame = layout?.frame ?? presentation?.frame ?? model.elementPresentationFrame(reference, fallback: element.frame)
        let cuts = erasures[element.id] ?? []
        let appearance = appearances[element.id]
        let erased = appearance?.state == .erased
        let paintsGraphic=graph.nodes[element.id]?.graphic != nil
        EditableElementContainer(reference: reference) {
          NotebookPlacedElement(presentation:presentation) {
          Group {
          if let graphic = graph.nodes[element.id]?.graphic {
            NotebookGraphicElementView(graphic: graphic, reference: reference, layout: layout,erasures:cuts,appearance:appearance)
          } else if element.kind == .nativeText {
            let target=model.nativeTextTarget(reference)
            NotebookNativeTextView(source:target?.source ?? element.source,style:target?.style ?? element.textStyle ?? .standard,reference:reference,
              isEditing:allowsInteraction && model.interactiveElementFocus == interactiveReference,
              onEditingEnded:{ if model.interactiveElementFocus == interactiveReference { model.interactiveElementFocus = nil } },retainedPage:element,draftTarget:target)
          } else if let presentation {
          PreparedAgentElementView(
            element: agentElementSnapshotSource(element),
            allowsInteraction: allowsInteraction,
            inputEnabled: inputEnabled,
            allowsProgramExecution: runningPrograms.contains(element.id),
            capturePolicy: capturePolicy(for:element,presentation:presentation),
            focus: interactiveReference,
            pageTurnActivity: pageTurnActivity,
            rasterPreparation: rasterPreparation,
            onFailure: onFailure,
            onRenderReady: { ready in
              setElement(element, ready: ready)
            },
            onState: { state, completion in
              // Focus gates admission inside the program. An already accepted
              // snapshot keeps its addressed writer through a later focus change.
              onState(element.id, state, completion)
            }
          )
          }
          }.erased(by:presentation == nil || paintsGraphic ? [] : cuts,appearance:presentation == nil || paintsGraphic ? nil : appearance)
          }
        }
        .frame(
          width: frame.width,
          height: frame.height
        )
        .erased(by:presentation == nil && !paintsGraphic ? cuts : [], appearance:presentation == nil && !paintsGraphic ? appearance : nil,transform:graph.nodes[element.id]?.graphic.transform,layout:layout)
        .environment(\.inkMaterialReadiness, .init(id:readinessID,report:{ id,content,ready in
          var next=readiness
          if next.recordMaterial(element.id,id:id,content:content,ready:ready) {
            readiness=next;publishReadiness()
          }
        }))
        .offset(x: frame.x, y: frame.y)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-element-\(element.id)")
        .accessibilityHidden(erased || (!cuts.isEmpty && appearance == nil))
        .allowsHitTesting(!erased && (cuts.isEmpty || appearance != nil))
      }
    }
    .coordinateSpace(name: NotebookManipulationSpace.material)
    .frame(width:pageSize.width,height:pageSize.height,alignment:.topLeading)
    .onAppear { publishReadiness() }
    .onChange(of: page.elementSourceIdentity) { _, _ in
      readiness.retain(page.elements)
      publishReadiness()
    }
    .onChange(of: page.drawingStamp) { _, _ in publishReadiness() }
    .onChange(of: pageSize) { _, _ in publishReadiness() }
  }


  private func setElement(_ element: AgentElement, ready: Bool) {
    if readiness.record(element, ready: ready) { publishReadiness() }
  }

  private func publishReadiness() {
    let display=display,cuts=paintedErasures
    var erasedIDs=Set<String>()
    let expected=Dictionary(uniqueKeysWithValues:display.elements.map { element in
      let graphic=display.graph.nodes[element.id]?.graphic
      let layout=display.layouts[element.id]
      let presentation=model.elementPresentation(.page(pageID:pageID,elementID:element.id),graph:display.graph)
      let frame=layout?.frame ?? element.frame
      let erasures=cuts[element.id] ?? []
      let appearance=model.elementErasureCache.preparedAppearance(surface:.page(pageID),id:element.id,
        graphic:graphic,layout:layout,size:presentation?.bodySize ?? .init(width:frame.width,height:frame.height),erasures:erasures)
      if appearance?.state == .erased || erasures.contains(where: { $0.target.wholeElement }) {
        erasedIDs.insert(element.id)
      }
      return (element.id,NotebookInkMaterialView.Content.required(graphic:graphic,
        layout:presentation == nil ? layout : nil,erasures:erasures,appearance:appearance))
    })
    let ready = readiness.isReady(for:display.elements,materials:expected,erasedIDs:erasedIDs)
    onRenderReady(ready)
    if ready {
      onErasurePresentation(.init(pageID:pageID,stamp:(model.pages[pageID] ?? page).drawingStamp,erasures:cuts))
    }
  }
}

/// Readiness names the exact source and state, not just an element whose ID can
/// survive an edit. A late teardown of the old source cannot clear its successor.
struct AgentOverlayReadiness {
  private var sources: [String: AgentElement] = [:]
  private var materials: [String:NotebookInkMaterialReadiness] = [:]
  mutating func recordMaterial(_ element:String,id:UUID,content:NotebookInkMaterialView.Content?,ready:Bool) -> Bool {
    materials[element,default:.init()].record(id,content:content,ready:ready)
  }

  @discardableResult mutating func record(_ element: AgentElement, ready: Bool) -> Bool {
    if ready {
      guard sources[element.id] != element else { return false }
      sources[element.id] = element
    } else {
      guard sources[element.id] == element else { return false }
      sources[element.id] = nil
    }
    return true
  }

  mutating func retain(_ elements: [AgentElement]) {
    let current = Dictionary(elements.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
    sources = sources.filter { current[$0.key] == $0.value }
    materials = materials.filter { current[$0.key] != nil }
  }

  func isReady(for elements: [AgentElement],materials required:[String:[NotebookInkMaterialView.Content]] = [:],
    erasedIDs:Set<String> = []) -> Bool {
    elements.allSatisfy { element in
      // A fully erased body is Color.clear: its retired WebKit/raster cannot
      // produce a source receipt. Undo must require that real source again.
      (erasedIDs.contains(element.id) || [.graphic,.nativeText].contains(element.kind) || sources[element.id] == element)
        && (materials[element.id] ?? .init()).isReady(for:required[element.id] ?? [])
    }
  }
}
