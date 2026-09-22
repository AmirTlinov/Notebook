import Foundation
import NotebookCore

/// The installed scene index owns ordinary interaction sources. Only accepted
/// insertions and active commands may differ from it; capture that small live
/// delta once per contact instead of searching the whole board per candidate.
struct NotebookSpatialInteractionDelta: Sendable {
  let ids:Set<String>
  let elements:[String:SpatialElement]
  let excluded:Set<String>
}

extension NotebookAppModel {
  func spatialInteractionDelta(boardID:UUID,graph:NotebookGraphicGraph)->NotebookSpatialInteractionDelta {
    var ids=Set(workingGraphics.compactMap { graphic -> String? in
      let belongs=graphic.surface == .board(boardID) || (graphic.surface.kind == .cover
        && graphic.surface.ownerID.flatMap { boardHierarchy?.ownerBoardID(of:$0) } == boardID)
      return belongs ? graphic.id : nil
    })
    ids.formUnion(elementCommandDrafts.keys.compactMap { reference in
      if case .spatial(let owner,let id)=reference,owner == boardID { return id };return nil
    })
    guard !ids.isEmpty else { return .init(ids:[],elements:[:],excluded:[]) }

    let groups=ids.filter { graph.groups[$0] != nil }
    // Parent motion changes descendant bounds without rewriting children. The
    // retained reverse ancestry visits that subtree, not every graph node.
    ids.formUnion(graph.descendantIDs(of:groups))

    var elements:[String:SpatialElement]=[:],excluded=Set<String>()
    if let board=boardHierarchy?.board(boardID) {
      // BoardDocument owns exact addressed lookup. Accepted local edits no
      // longer turn the next Pencil contact into a full board traversal.
      for id in ids {
        guard let element=board.element(id:id) else { continue }
        let reference=EditableElementReference.spatial(boardID:boardID,elementID:element.id)
        if elementCommandDrafts[reference]?.removed == true { excluded.insert(element.id);continue }
        elements[element.id]=elementCommandDrafts[reference]?.projecting(element) ?? element
      }
    }
    for reference in elementCommandDrafts.keys {
      guard case .spatial(let owner,let id)=reference,owner == boardID,ids.contains(id),
        elementCommandDrafts[reference]?.removed == true else { continue }
      excluded.insert(id)
    }
    return .init(ids:ids,elements:elements,excluded:excluded)
  }
}
