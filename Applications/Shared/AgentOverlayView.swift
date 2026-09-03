import NotebookCore
import SwiftUI

struct AgentOverlayView: View {
  let elements: [AgentElement]
  let isElementEditingEnabled: Bool
  let onMove: (String, CGSize) -> Void
  let onDelete: (String) -> Void
  let onRenderReady: (Bool) -> Void
  let onState: (String, JSONValue) -> Void

  @State private var readyElementIDs: Set<String> = []
  @State private var selectedElementID: String?

  var body: some View {
    ZStack(alignment: .topLeading) {
      if isElementEditingEnabled {
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture { selectedElementID = nil }
      }

      ForEach(elements) { element in
        EditableElementContainer(
          isEditingEnabled: isElementEditingEnabled,
          isSelected: selectedElementID == element.id,
          coordinateScale: 1,
          onSelect: { selectedElementID = element.id },
          onMove: { translation in
            onMove(element.id, translation)
          },
          onDelete: {
            selectedElementID = nil
            onDelete(element.id)
          }
        ) {
          AgentWebElementView(
            element: element,
            onRenderReady: { ready in
              setElement(element.id, ready: ready)
            },
            onState: { state in
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
      readyElementIDs.formIntersection(liveIDs)
      if let selectedElementID, !liveIDs.contains(selectedElementID) {
        self.selectedElementID = nil
      }
      publishReadiness()
    }
    .onChange(of: isElementEditingEnabled) { _, enabled in
      if !enabled { selectedElementID = nil }
    }
  }

  private func setElement(_ id: String, ready: Bool) {
    if ready {
      readyElementIDs.insert(id)
    } else {
      readyElementIDs.remove(id)
    }
    publishReadiness()
  }

  private func publishReadiness() {
    let expected = Set(elements.map(\.id))
    onRenderReady(expected.isSubset(of: readyElementIDs))
  }
}
