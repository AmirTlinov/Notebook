import NotebookCore
import SwiftUI

struct AgentOverlayView: View {
  @Environment(NotebookAppModel.self) private var model

  let pageID: UUID
  let elements: [AgentElement]
  let allowsInteraction: Bool
  let onRenderReady: (Bool) -> Void
  let onState: (String, JSONValue) -> Void

  @State private var readiness = AgentOverlayReadiness()

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(elements) { element in
        let reference = EditableElementReference.page(
          pageID: pageID,
          elementID: element.id
        )
        let interactiveReference = InteractiveElementReference.page(pageID: pageID, elementID: element.id)
        EditableElementContainer(reference: reference, coordinateScale: 1) {
          PreparedAgentElementView(
            element: element,
            allowsInteraction: allowsInteraction,
            focus: interactiveReference,
            onRenderReady: { ready in
              setElement(element, ready: ready)
            },
            onState: { state in
              guard allowsInteraction, model.interactiveElementFocus == interactiveReference else { return }
              onState(element.id, state)
            }
          )
        }
        .frame(
          width: element.frame.width,
          height: element.frame.height
        )
        .offset(x: element.frame.x, y: element.frame.y)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-element-\(element.id)")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear { publishReadiness() }
    .onChange(of: elements) { _, updatedElements in
      let liveIDs = Set(updatedElements.map(\.id))
      readiness.retain(updatedElements)
      if case .page(let selectedPageID, let selectedElementID) =
        model.selectionSession.element,
        selectedPageID == pageID,
        !liveIDs.contains(selectedElementID)
      {
        model.clearSelection()
      }
      publishReadiness()
    }
  }


  private func setElement(_ element: AgentElement, ready: Bool) {
    readiness.record(element, ready: ready)
    publishReadiness()
  }

  private func publishReadiness() {
    onRenderReady(readiness.isReady(for: elements))
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
    elements.allSatisfy { sources[$0.id] == $0 }
  }
}
