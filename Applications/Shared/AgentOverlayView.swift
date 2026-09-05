import NotebookCore
import SwiftUI

struct AgentOverlayView: View {
  @Environment(NotebookAppModel.self) private var model

  let pageID: UUID
  let elements: [AgentElement]
  let isElementEditingEnabled: Bool
  let onRenderReady: (Bool) -> Void
  let onState: (String, JSONValue) -> Void

  @State private var readyElementIDs: Set<String> = []

  var body: some View {
    ZStack(alignment: .topLeading) {
      if isElementEditingEnabled {
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture { model.clearElementSelection() }
      }

      ForEach(elements) { element in
        let reference = EditableElementReference.page(
          pageID: pageID,
          elementID: element.id
        )
        EditableElementContainer(
          isEditingEnabled: isElementEditingEnabled,
          isSelected: model.elementEditingSession.selection == reference,
          coordinateScale: 1,
          translation: translation(for: reference),
          isContentInteractive: !element.javaScript.isEmpty,
          onSelect: { model.selectElement(reference) },
          onDragChanged: { translation in
            model.updateElementDrag(reference, translation: translation)
          },
          onDragEnded: { translation in
            model.finishElementDrag(reference, translation: translation)
          },
          onResizeChanged: { model.updateElementResize(reference, delta: $0) },
          onResizeEnded: { model.finishElementResize(reference, delta: $0) },
          resizeDelta: model.elementResizeDelta(reference),
          onDelete: { model.deleteElement(reference) }
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
      if case .page(let selectedPageID, let selectedElementID) =
        model.elementEditingSession.selection,
        selectedPageID == pageID,
        !liveIDs.contains(selectedElementID)
      {
        model.clearElementSelection()
      }
      publishReadiness()
    }
  }

  private func translation(
    for reference: EditableElementReference
  ) -> SpatialPoint {
    guard model.elementEditingSession.selection == reference else {
      return .zero
    }
    return model.elementEditingSession.translation
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
