import NotebookCore
import SwiftUI

struct AgentOverlayView: View {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.displayScale) private var displayScale

  let pageID: UUID
  let pageSize: PageSize
  let renderingScale: Double
  let elements: [AgentElement]
  let allowsInteraction: Bool
  let inputEnabled: Bool
  let onRenderReady: (Bool) -> Void
  let onState: (String, JSONValue) -> Bool
  var graphicPresentation = NotebookGraphicPresentation([])
  var visibleRegion: CGRect? = nil

  @State private var readiness = AgentOverlayReadiness()

  private var graph: NotebookGraphicGraph {
    if let page = model.pages[pageID] { return model.graphicGraph(page:page) }
    return .init(elements.compactMap { element in
      guard let graphic = element.graphic else { return nil }
      return .init(id:element.id,graphic:graphic,frame:element.frame,surface:.page(pageID),shown:graphicPresentation.geometryIDs.contains(element.id))
    })
  }

  private var visibleElements: [AgentElement] {
    let graph = graph
    return elements.filter {
      guard $0.kind != .group else { return false }
      if $0.graphic != nil {
        guard let frame = graph.resolve($0.id).layout?.frame else { return false }
        return frame.x < pageSize.width && frame.y < pageSize.height && frame.x+frame.width > 0 && frame.y+frame.height > 0
      }
      return captureRegion(for: $0) != nil
    }
  }

  private func captureRegion(for element: AgentElement) -> PageRect? {
    let frame = element.frame
    let left = max(0, frame.x), top = max(0, frame.y)
    let right = min(pageSize.width, frame.x + frame.width), bottom = min(pageSize.height, frame.y + frame.height)
    guard right > left, bottom > top else { return nil }
    return .init(x: left - frame.x, y: top - frame.y, width: right - left, height: bottom - top)
  }

  private func capturePolicy(for element: AgentElement) -> AgentSnapshotPolicy {
    let region = captureRegion(for: element)!
    let density = renderingScale * displayScale
    // A full physical source keeps its canonical cache identity. A clipped
    // source uses the existing regional capture and its original local origin.
    if region.x == 0, region.y == 0, region.width == element.frame.width, region.height == element.frame.height {
      return .exact(scale: density)
    }
    return .region(region, scale: density)
  }

  private func runtimeIDs(in elements: [AgentElement]) -> Set<String> {
    Set(elements.filter { element in
      element.kind == .web && (visibleRegion.map {
        $0.intersects(CGRect(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height))
      } ?? true)
    }.map(\.id))
  }

  var body: some View {
    let visible = visibleElements
    let graph = graph
    let erasures = model.elementErasures(on: .page(pageID))
    let runningPrograms = runtimeIDs(in: visible)
    // Observe completion in this body, not only in the deferred ForEach builder.
    let appearances = Dictionary(uniqueKeysWithValues: visible.compactMap { element -> (String, NotebookElementAppearance)? in
      let reference = EditableElementReference.page(pageID:pageID,elementID:element.id)
      let layout = element.graphic == nil ? nil : graph.resolve(element.id).layout
      let frame = layout?.frame ?? model.elementPresentationFrame(reference,fallback:element.frame)
      guard let value = model.elementErasureCache.appearance(surface:.page(pageID),id:element.id,
        graphic:graph.nodes[element.id]?.graphic,layout:layout,size:.init(width:frame.width,height:frame.height),
        erasures:erasures[element.id] ?? []) else { return nil }
      return (element.id,value)
    })
    ZStack(alignment: .topLeading) {
      ForEach(visible) { element in
        let reference = EditableElementReference.page(
          pageID: pageID,
          elementID: element.id
        )
        let interactiveReference = InteractiveElementReference.page(pageID: pageID, elementID: element.id)
        let layout = element.graphic == nil ? nil : graph.resolve(element.id).layout
        let frame = layout?.frame ?? model.elementPresentationFrame(reference, fallback: element.frame)
        let cuts = erasures[element.id] ?? []
        let appearance = appearances[element.id]
        let erased = appearance?.state == .erased
        EditableElementContainer(reference: reference, coordinateScale: 1) {
          if let graphic = graph.nodes[element.id]?.graphic {
            NotebookGraphicElementView(graphic: graphic, reference: reference, layout: layout)
          } else if element.kind == .nativeText {
            NotebookNativeTextView(source:element.source,style:element.textStyle ?? .standard,reference:reference,
              frame:frame,maximumHeight:pageSize.height-frame.y,isEditing:allowsInteraction && model.interactiveElementFocus == interactiveReference,
              onEditingEnded:{ if model.interactiveElementFocus == interactiveReference { model.interactiveElementFocus = nil } },retainedPage:element)
          } else {
          PreparedAgentElementView(
            element: element,
            allowsInteraction: allowsInteraction,
            inputEnabled: inputEnabled,
            allowsProgramExecution: runningPrograms.contains(element.id),
            capturePolicy: capturePolicy(for: element),
            focus: interactiveReference,
            onRenderReady: { ready in
              setElement(element, ready: ready)
            },
            onState: { state in
              guard allowsInteraction, model.interactiveElementFocus == interactiveReference else { return false }
              return onState(element.id, state)
            }
          )
          }
        }
        .frame(
          width: frame.width,
          height: frame.height
        )
        .erased(by: cuts, appearance:appearance,transform:graph.nodes[element.id]?.graphic.transform,layout:layout)
        .offset(x: frame.x, y: frame.y)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-element-\(element.id)")
        .accessibilityHidden(erased || (!cuts.isEmpty && appearance == nil))
        .allowsHitTesting(!erased && (cuts.isEmpty || appearance != nil))
      }
    }
    .coordinateSpace(name: NotebookManipulationSpace.material)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear { publishReadiness() }
    .onChange(of: elements) { _, updatedElements in
      readiness.retain(updatedElements)
      publishReadiness()
    }
    .onChange(of: pageSize) { _, _ in publishReadiness() }
  }


  private func setElement(_ element: AgentElement, ready: Bool) {
    readiness.record(element, ready: ready)
    publishReadiness()
  }

  private func publishReadiness() {
    onRenderReady(readiness.isReady(for: visibleElements))
  }
}

/// Readiness names the exact source and state, not just an element whose ID can
/// survive an edit. A late teardown of the old source cannot clear its successor.
struct AgentOverlayReadiness {
  private var sources: [String: AgentElement] = [:]

  mutating func record(_ element: AgentElement, ready: Bool) {
    if ready { sources[element.id] = element }
    else if sources[element.id] == element { sources[element.id] = nil }
  }

  mutating func retain(_ elements: [AgentElement]) {
    let current = Dictionary(elements.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
    sources = sources.filter { current[$0.key] == $0.value }
  }

  func isReady(for elements: [AgentElement]) -> Bool {
    elements.allSatisfy { [.graphic,.nativeText].contains($0.kind) || sources[$0.id] == $0 }
  }
}
