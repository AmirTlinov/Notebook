import NotebookCore
import SwiftUI

/// A contiguous native run in the existing camera plane. One Canvas paints
/// every path in source order; only the active label has an input view. The
/// parent supplies its installed projection, never a second graphics camera.
struct NotebookGraphicBatchView: View {
  @Environment(NotebookAppModel.self) private var model
  let run: SceneCompositionVectorRun
  let elements: [SpatialElement]
  let graph: NotebookGraphicGraph
  let scale: Double
  let size: CGSize
  let projectOrigin: (WorldPoint) -> CGPoint
  var commitsState = true

  private struct Object: Identifiable {
    let element: SpatialElement
    let layout: NotebookGraphicLayout
    let frame: CGRect
    var id: String { element.id }
  }

  private var objects: [Object] {
    let sources = Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) })
    return run.owners.compactMap { owner in
      guard case .element(let id) = owner.id, let element = sources[id], element.graphic != nil,
        let layout = graph.resolve(id).layout else { return nil }
      let origin = projectOrigin(element.worldOrigin ?? .zero), local = layout.frame
      return .init(element: element, layout: layout, frame: .init(
        x: origin.x + local.x * scale, y: origin.y + local.y * scale,
        width: local.width * scale, height: local.height * scale))
    }
  }
  private var editingID: String? {
    guard commitsState, case .board(let boardID, let id) = model.interactiveElementFocus,
      boardID == run.plane.boardID else { return nil }
    return id
  }

  var body: some View {
    let objects = objects, editingID = editingID
    ZStack(alignment: .topLeading) {
      Canvas { context, _ in
        for object in objects where object.id != editingID {
          var local = context
          local.translateBy(x: object.frame.minX, y: object.frame.minY)
          local.scaleBy(x: scale, y: scale)
          NotebookGraphicView.paint(object.element.graphic!, layout: object.layout, in: local,
            size: .init(width: object.layout.frame.width, height: object.layout.frame.height))
        }
      }
      .accessibilityRepresentation {
        ZStack(alignment: .topLeading) {
          ForEach(objects.filter { $0.id != editingID }) { object in
            accessibleObject(object)
              .frame(width: object.frame.width, height: object.frame.height)
              .position(x: object.frame.midX, y: object.frame.midY)
          }
        }.frame(width: size.width, height: size.height)
      }
      .allowsHitTesting(false)
      if let object = objects.first(where: { $0.id == editingID }) {
        NotebookGraphicElementView(graphic: object.element.graphic!, reference: reference(object.id), layout: object.layout)
          .frame(width: object.layout.frame.width, height: object.layout.frame.height)
          .scaleEffect(scale)
          .frame(width: object.frame.width, height: object.frame.height)
          .position(x: object.frame.midX, y: object.frame.midY)
      }
    }.frame(width: size.width, height: size.height)
  }

  private func reference(_ id: String) -> EditableElementReference {
    .spatial(boardID: run.plane.boardID, elementID: id)
  }

  @ViewBuilder private func accessibleObject(_ object: Object) -> some View {
    let graphic = object.element.graphic!
    let content = Color.clear.accessibilityElement(children: .ignore)
      .accessibilityLabel(graphic.label.isEmpty ? (graphic.shape == .ellipse ? "Эллипс" : "Связь") : graphic.label)
      .accessibilityAddTraits(.isImage)
    if commitsState {
      EditableElementContainer(reference: reference(object.id), coordinateScale: scale) { content }
    } else { content }
  }
}
