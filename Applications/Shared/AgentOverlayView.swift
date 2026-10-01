import NotebookCore
import SwiftUI

struct AgentOverlayView: View {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.displayScale) private var displayScale

  let page:PageDocument
  let sourceIdentity: ObjectIdentifier
  let renderingScale: Double
  var preparedDisplay:NotebookPageGraphicDisplay? = nil
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
  var preparations: PageAgentPreparationOwner? = nil
  var onFailure: (PageTurnPreparationFailure) -> Void = { _ in }
  #if DEBUG
  var onReadinessDiagnostic: (@escaping () -> String) -> Void = { _ in }
  #endif

  @State private var readiness = AgentOverlayReadiness()
  @State private var readinessID = UUID()

  private var display:NotebookPageGraphicDisplay { preparedDisplay ?? model.pageGraphicDisplay(page,in:visibleRegion) }

  private var paintedErasures: InkElementErasureMap {
    #if os(iOS)
    model.pagePresentationErasures(page)
    #else
    model.elementErasures(on: .page(pageID))
    #endif
  }

  private func ordered(_ id:String,graph:NotebookGraphicGraph)->Bool {
    guard let node=graph.node(id),node.placement.parentID == nil else {return false}
    return node.graphic.sourceInkContactID != nil
  }

  private func capturePolicy(for element: AgentElement, presentation:NotebookElementPresentation) -> AgentSnapshotPolicy {
    PageAgentPreparationOwner.capturePolicy(for: element, presentation: presentation, pageSize: pageSize,
      renderingScale: renderingScale, displayScale: displayScale)
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
    // Requirements and receipts describe this tree, not a later model version.
    // Image completion only updates exact facts in the non-observable ledger.
    let expected = Dictionary(uniqueKeysWithValues: visible.map { element in
      (element.id, ordered(element.id,graph:graph) ? []:NotebookInkMaterialView.Content.required(graphic: graph.nodes[element.id]?.graphic,
        layout: presentations[element.id] == nil ? display.layouts[element.id] : nil,
        erasures: erasures[element.id] ?? [], appearance: appearances[element.id]))
    })
    let erasedIDs = Set(visible.compactMap { element -> String? in
      appearances[element.id]?.state == .erased
        || (erasures[element.id] ?? []).contains(where: { $0.target.wholeElement }) ? element.id : nil
    })
    let onReady = onRenderReady, onErasure = onErasurePresentation
    let presentationID = readiness.prepare(sourceIdentity: sourceIdentity,
      elements: visible, materials: expected, erasedIDs: erasedIDs,
      pageSize: pageSize, erasure: .init(pageID: pageID,
        stamp: (model.pagePresentationSource(pageID) ?? page).drawingStamp, erasures: erasures),
      publish: { ready, receipt in
        onReady(ready)
        if ready { onErasure(receipt) }
      })
    ZStack(alignment: .topLeading) {
      ForEach(visible) { element in
        let reference = EditableElementReference.page(
          pageID: pageID,
          elementID: element.id
        )
        let interactiveReference = InteractiveElementReference.page(pageID: pageID, elementID: element.id)
        #if os(iOS)
        let canHost=allowsInteraction && inputEnabled && model.presence?.notebookPageID == pageID
        let held=canHost ? model.selectedGraphicHosts.heldMember(reference) : nil
        let heldSelectionID=canHost ? model.selectedGraphicHosts.selectionID(for:reference) : nil
        #else
        let held:NotebookGraphicSelection.Member?=nil
        let heldSelectionID:UUID?=nil
        #endif
        let targetLayout=display.layouts[element.id]
        let targetGraphic=graph.nodes[element.id]?.graphic
        let layout = held?.layout ?? targetLayout
        let graphic=held?.graphic ?? targetGraphic
        let presentation=presentations[element.id]
        let frame = layout?.frame ?? presentation?.frame ?? model.elementPresentationFrame(reference, fallback: element.frame)
        let targetFrame=targetLayout?.frame ?? frame
        let selectedHostID=graphic?.sourceInkContactID == nil && graphic != nil ? heldSelectionID : nil
        #if os(iOS)
        let selectedTextHostID=element.kind == .nativeText &&
          (!model.selectionSession.ink.isEmpty || model.selectedGraphicHosts.heldSelectionID(reference) != nil)
          ? heldSelectionID : nil
        #else
        let selectedTextHostID:UUID?=nil
        #endif
        let cuts = erasures[element.id] ?? []
        let appearance = appearances[element.id]
        let erased = appearance?.state == .erased
        let paintsGraphic=graphic != nil
        EditableElementContainer(reference: reference) {
          NotebookPlacedElement(presentation:presentation) {
          Group {
          if let graphic {
            NotebookGraphicElementView(graphic: graphic, reference: reference, layout: layout,erasures:cuts,appearance:appearance,paintsMeasuredBody:!ordered(element.id,graph:graph))
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
            preparations: preparations,
            rasterPreparation: rasterPreparation,
            onFailure: onFailure,
            onRenderReady: { ready in
              if readiness.record(element, ready: ready) { readiness.publish() }
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
        // Clip the authored body before it enters the movable native host.
        // An outer SwiftUI mask would remain at the original wrapper frame
        // and erase the body as soon as the host translates beyond it.
        .erased(by:presentation == nil && !paintsGraphic ? cuts : [], appearance:presentation == nil && !paintsGraphic ? appearance : nil,transform:graph.nodes[element.id]?.graphic.transform,layout:layout)
        .modifier(NotebookSelectedGraphicHostModifier(reference:reference,selectionID:selectedHostID,
          size:.init(width:frame.width,height:frame.height),graphic:graphic,layout:layout,
          targetGraphic:targetGraphic,targetLayout:targetLayout,
          targetSize:.init(width:targetFrame.width,height:targetFrame.height),
          targetOffset:.init(x:targetFrame.x+targetFrame.width/2-frame.x-frame.width/2,
            y:targetFrame.y+targetFrame.height/2-frame.y-frame.height/2),
          targetContent:selectedHostID.flatMap { _ in targetGraphic.map { target in AnyView(
            NotebookGraphicElementView(graphic:target,reference:reference,layout:targetLayout,
              erasures:cuts,appearance:appearance,paintsMeasuredBody:!ordered(element.id,graph:graph))
              .frame(width:targetFrame.width,height:targetFrame.height)) } }))
        .modifier(NotebookSelectedTextHostModifier(reference:reference,selectionID:selectedTextHostID,
          size:.init(width:frame.width,height:frame.height)))
        .frame(
          width: frame.width,
          height: frame.height
        )
        .environment(\.inkMaterialReadiness, .init(id:readinessID,report:{ id,content,ready in
          if readiness.recordMaterial(element.id,id:id,content:content,ready:ready) {
            readiness.publish()
          }
        },page:pageTurnActivity.flatMap { activity in
          rasterPreparation.map { (activity:activity,index:$0.pageIndex) }
        }))
        .offset(x: frame.x, y: frame.y)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-element-\(element.id)")
        .accessibilityHidden(erased || (!cuts.isEmpty && appearance == nil))
        // The selected native host is a painter, not a second gesture owner.
        // Whole-selection controls and the existing input gate own the drag.
        .allowsHitTesting(selectedHostID == nil && !erased && (cuts.isEmpty || appearance != nil))
      }
    }
    .coordinateSpace(name: NotebookManipulationSpace.material)
    .frame(width:pageSize.width,height:pageSize.height,alignment:.topLeading)
    .onChange(of: presentationID, initial: true) { [readiness] _, _ in
      #if DEBUG
      onReadinessDiagnostic { [weak readiness] in readiness?.diagnostic() ?? "retired" }
      #endif
      readiness.publish()
    }
  }
}

/// Readiness names the exact source and state, not just an element whose ID can
/// survive an edit. A late teardown of the old source cannot clear its successor.
// Receipt mutations do not invalidate SwiftUI or copy the entire ledger. The
// one current immutable presentation changes only when the rendered tree does.
@MainActor final class AgentOverlayReadiness {
  private struct Presentation {
    let id = UUID()
    let sourceIdentity: ObjectIdentifier
    let elements: [String: AgentElement]
    let materials: [String: [NotebookInkMaterialView.Content]]
    let erasedIDs: Set<String>
    let pageSize: PageSize
    let erasure: PageElementErasurePresentation

    func matches(sourceIdentity: ObjectIdentifier, elements: [String: AgentElement], materials: [String: [NotebookInkMaterialView.Content]],
      erasedIDs: Set<String>, pageSize: PageSize, erasure: PageElementErasurePresentation) -> Bool {
      self.sourceIdentity == sourceIdentity && self.elements == elements && self.materials == materials && self.erasedIDs == erasedIDs
        && self.pageSize == pageSize && self.erasure.pageID == erasure.pageID
        && self.erasure.stamp == erasure.stamp && self.erasure.erasures == erasure.erasures
    }
  }
  private var presentation: Presentation?
  private var publisher: ((Bool, PageElementErasurePresentation) -> Void)?
  private var published: (presentationID: UUID, ready: Bool)?
  private var sources: [String: AgentElement] = [:]
  private var materials: [String: NotebookInkMaterialReadiness] = [:]
  #if DEBUG
  func diagnostic() -> String {
    guard let presentation else { return "unprepared" }
    let waiting = presentation.elements.values.compactMap { element -> String? in
      let sourceReady = presentation.erasedIDs.contains(element.id) || [.graphic,.nativeText].contains(element.kind)
        || sources[element.id] == element
      let materialReady = (materials[element.id] ?? .init()).isReady(for: presentation.materials[element.id] ?? [])
      return sourceReady && materialReady ? nil : "\(element.id):source=\(sourceReady),material=\(materialReady)"
    }.sorted()
    return "waiting=\(waiting)"
  }
  #endif

  /// Called once by body. No callback below reads the model or rebuilds layout.
  /// The publisher captures only the parent's callbacks, never this ledger.
  func prepare(sourceIdentity: ObjectIdentifier, elements: [AgentElement], materials: [String: [NotebookInkMaterialView.Content]] = [:],
    erasedIDs: Set<String> = [], pageSize: PageSize, erasure: PageElementErasurePresentation,
    publish: @escaping (Bool, PageElementErasurePresentation) -> Void) -> UUID {
    let elements = Dictionary(elements.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
    publisher = publish
    if let presentation, presentation.matches(sourceIdentity: sourceIdentity, elements: elements, materials: materials, erasedIDs: erasedIDs,
      pageSize: pageSize, erasure: erasure) { return presentation.id }
    // A first durable read can replace a locally created page's immutable
    // envelope without changing its artwork. Rebind that exact source receipt
    // through the normal publication edge, retaining unchanged installed facts.
    let next = Presentation(sourceIdentity: sourceIdentity, elements: elements, materials: materials, erasedIDs: erasedIDs,
      pageSize: pageSize, erasure: erasure)
    presentation = next
    sources = sources.filter { elements[$0.key] == $0.value }
    self.materials = self.materials.filter { elements[$0.key] != nil }
    return next.id
  }

  func publish() {
    guard let presentation, let publisher else { return }
    let ready = presentation.elements.values.allSatisfy { element in
      // A fully erased body has no source view. Undo requires its real source.
      (presentation.erasedIDs.contains(element.id) || [.graphic,.nativeText].contains(element.kind)
        || sources[element.id] == element)
        && (materials[element.id] ?? .init()).isReady(for: presentation.materials[element.id] ?? [])
    }
    // Facts arrive separately for every installed source/material. Only a new
    // immutable presentation or a readiness transition changes the parent's
    // receipt; intermediate facts stay in this ledger. The presentation ID
    // includes erasure requirements, so a new cut still receives its own ack.
    guard published?.presentationID != presentation.id || published?.ready != ready else { return }
    published = (presentation.id, ready)
    publisher(ready, presentation.erasure)
  }

  @discardableResult
  func recordMaterial(_ element: String, id: UUID, content: NotebookInkMaterialView.Content?, ready: Bool) -> Bool {
    guard presentation?.elements[element] != nil else { return false }
    return materials[element, default: .init()].record(id, content: content, ready: ready)
  }

  @discardableResult
  func record(_ element: AgentElement, ready: Bool) -> Bool {
    if ready {
      guard presentation?.elements[element.id] == element, sources[element.id] != element else { return false }
      sources[element.id] = element
    } else {
      guard sources[element.id] == element else { return false }
      sources[element.id] = nil
    }
    return true
  }
}
