import NotebookCore
import SwiftUI

struct AgentOverlayView: View {
  let elements: [AgentElement]
  let onRenderReady: (Bool) -> Void
  let onState: (String, JSONValue) -> Void

  @State private var readyElementIDs: Set<String> = []

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(elements) { element in
        AgentWebElementView(
          element: element,
          onRenderReady: { ready in
            setElement(element.id, ready: ready)
          },
          onState: { state in
            onState(element.id, state)
          }
        )
        .frame(
          width: element.frame.width,
          height: element.frame.height
        )
        .offset(x: element.frame.x, y: element.frame.y)
      }
    }
    .onAppear { publishReadiness() }
    .onChange(of: elements) { _, updatedElements in
      let liveIDs = Set(updatedElements.map(\.id))
      readyElementIDs.formIntersection(liveIDs)
      publishReadiness()
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
