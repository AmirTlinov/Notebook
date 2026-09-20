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

struct NotebookElementCommandDraft: Equatable {
  let source: NotebookElementPlacement.Source
  let graphic: NotebookGraphic?
  var frame: PageRect { source.frame }
  var basis: NotebookElementBasis? { source.basis }
  var rect: CGRect { .init(x: frame.x, y: frame.y, width: frame.width, height: frame.height) }
}

extension NotebookAppModel {
  func retireGraphicCommands(through cursor: UInt64) {
    for (reference, command) in elementCommandSources {
      guard !editingNativeTextReferences.contains(reference), let accepted = command.cursor, cursor >= accepted else { continue }
      elementCommandSources[reference] = nil
      elementCommandDrafts[reference] = nil
    }
  }

  /// Whole and leaf drafts enter the one placement resolver before children
  /// are resolved. Never rewrite each child's local frame to preview its parent.
  func elementPlacementDrafts(reference: (String) -> EditableElementReference) -> [String:NotebookElementPlacement.Source] {
    var result:[String:NotebookElementPlacement.Source]=[:]
    for (ref,draft) in elementCommandDrafts {
      let id:String
      switch ref { case .page(_,let value),.spatial(_,let value): id=value }
      if reference(id) == ref { result[id]=draft.source }
    }
    if let contact=selectionSession.manipulation {
      let ref=contact.reference,id:String
      switch ref { case .page(_,let value),.spatial(_,let value): id=value }
      if reference(id) == ref,var source=result[id] ?? nativeElementSource(ref)?.placementSource {
        source.frame = .init(x:contact.frame.minX,y:contact.frame.minY,width:contact.frame.width,height:contact.frame.height)
        source.basis=contact.basis;result[id]=source
      }
    }
    return result
  }

  /// Contact and accepted edits share the existing graph, renderer and camera.
  /// Only nodes already admitted by that graph can change here.
  func projectingGraphicCommands(_ graph: NotebookGraphicGraph,
    reference: (String) -> EditableElementReference) -> NotebookGraphicGraph {
    let selectedEdits = Dictionary(uniqueKeysWithValues:(selectionSession.manipulation?.selectedEdits ?? []).map { ($0.id,$0) })
    return graph.replacingNodes(graph.nodes.values.compactMap { node in
      let ref = reference(node.id), draft = elementCommandDrafts[ref]
      let contact = selectionSession.manipulation.flatMap { $0.reference == ref ? $0 : nil }
      var graphic = draft?.graphic ?? node.graphic
      if let connection = contact?.connection { graphic.connection = connection }
      if let contact {
        if contact.vertices != contact.originalVertices { graphic.vertices = contact.vertices }
        if contact.cornerRadius != contact.originalCornerRadius { graphic.cornerRadius = contact.cornerRadius }
      }
      let selected = selectedEdits[node.id]
      if let selected { graphic = selected.graphic }
      let frame = selected?.frame ?? contact.map { PageRect(x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width, height: $0.frame.height) }
        ?? draft?.frame ?? node.frame
      let basis = contact?.basis ?? draft?.basis ?? node.placement.basis
      let placement:NotebookElementPlacement
      if frame == node.frame,basis == node.placement.basis { placement=node.placement }
      else {
        guard let changed=try? node.placement.updating(frame:frame,basis:basis) else { return nil }
        placement=changed
      }
      return .init(id:node.id,graphic:graphic,frame:frame,surface:node.surface,
        shown:node.shown && graphic.showsGeometry,placement:placement)
    })
  }
}

struct NotebookElementEdit {
  let reference: EditableElementReference
  let kind: CollaborationOperation.Kind
  let values: [String: JSONValue]
}
