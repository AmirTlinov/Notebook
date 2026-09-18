import Foundation
import NotebookCore

/// Exact persisted source of the preceding command on this physical element.
/// The serial writer may advance our own source, never silently rebase onto a
/// peer's edit. A failed predecessor cancels its dependent commands.
struct NotebookElementCommandResult: Sendable {
  let page: AgentElement?
  let spatial: SpatialElement?
}

struct NotebookElementCommand {
  let id: UUID
  let task: Task<NotebookElementCommandResult?, Never>
  var cursor: UInt64?
}

struct NotebookGraphicCommandDraft: Equatable {
  let frame: PageRect
  let graphic: NotebookGraphic
  var rect: CGRect { .init(x: frame.x, y: frame.y, width: frame.width, height: frame.height) }
}

extension NotebookAppModel {
  func retireGraphicCommands(through cursor: UInt64) {
    for (reference, command) in elementCommandSources {
      guard let accepted = command.cursor, cursor >= accepted else { continue }
      elementCommandSources[reference] = nil
      graphicCommandDrafts[reference] = nil
    }
  }

  /// Contact and accepted edits share the existing graph, renderer and camera.
  /// Only nodes already admitted by that graph can change here.
  func projectingGraphicCommands(_ graph: NotebookGraphicGraph,
    reference: (String) -> EditableElementReference) -> NotebookGraphicGraph {
    .init(graph.nodes.values.map { node in
      let ref = reference(node.id), draft = graphicCommandDrafts[ref]
      let contact = selectionSession.manipulation.flatMap { $0.reference == ref ? $0 : nil }
      var graphic = draft?.graphic ?? node.graphic
      if let connection = contact?.connection { graphic.connection = connection }
      if let contact {
        if contact.vertices != contact.originalVertices { graphic.vertices = contact.vertices }
        if contact.cornerRadius != contact.originalCornerRadius { graphic.cornerRadius = contact.cornerRadius }
      }
      let frame = contact.map { PageRect(x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width, height: $0.frame.height) }
        ?? draft?.frame ?? node.frame
      return .init(id: node.id, graphic: graphic, frame: frame, origin: node.origin, surface: node.surface,
        shown: node.shown && graphic.showsGeometry)
    })
  }
}
