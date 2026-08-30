import SwiftUI
import NotebookCore

struct AgentOverlayView: View {
  let elements: [AgentElement]
  let onState: (String, JSONValue) -> Void

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(elements) { element in
        AgentWebElementView(element: element) { state in
          onState(element.id, state)
        }
        .frame(
          width: element.frame.width,
          height: element.frame.height
        )
        .offset(x: element.frame.x, y: element.frame.y)
      }
    }
  }
}
