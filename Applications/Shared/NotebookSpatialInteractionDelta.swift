import CoreGraphics
import Foundation
import NotebookCore

/// The installed scene index owns ordinary interaction sources. Only accepted
/// insertions and active commands may differ from it; capture that small live
/// delta once per contact instead of searching the whole board per candidate.
struct NotebookSpatialInteractionDelta: Sendable {
  let ids:Set<String>
  let elements:[String:SpatialElement]
  let excluded:Set<String>
  let movedGroups:[MovedGroup]

  struct MovedGroup: Sendable {
    let id:String
    let surface:SurfaceID
    let current:NotebookElementPlacement

    /// Map a current world query into this whole's unchanged local frame.
    /// Exact geometry is still resolved from `current`; this is broad phase.
    func localBounds(for bounds:WorkspaceSpatialBounds)->CGRect? {
      let transform=current.transform,determinant=transform.a*transform.d-transform.b*transform.c
      guard determinant.isFinite,determinant != 0 else { return nil }
      let inverse=transform.inverted()
      let corners=[bounds.origin,bounds.origin.offsetBy(x:bounds.width,y:0),
        bounds.origin.offsetBy(x:0,y:bounds.height),bounds.maximum]
      let projected=corners.map { point -> CGPoint in
        let offset=current.origin.delta(to:point)
        return CGPoint(x:offset.x,y:offset.y).applying(inverse)
      }
      guard let minX=projected.map(\.x).min(),let minY=projected.map(\.y).min(),
        let maxX=projected.map(\.x).max(),let maxY=projected.map(\.y).max(),
        [minX,minY,maxX,maxY].allSatisfy(\.isFinite) else { return nil }
      return .init(x:minX,y:minY,width:max(0,maxX-minX),height:max(0,maxY-minY))
    }
  }

  init(ids:Set<String>,elements:[String:SpatialElement],excluded:Set<String>,
    movedGroups:[MovedGroup] = []) {
    self.ids=ids;self.elements=elements;self.excluded=excluded;self.movedGroups=movedGroups
  }

  /// A moved whole does not expand into every descendant on Pencil-down.
  /// Query the retained local-frame hierarchy; unrelated overlapping objects
  /// never consume this whole's candidate budget.
  func movedCandidateIDs(surface:SurfaceID,bounds:WorkspaceSpatialBounds,
    graph:NotebookGraphicGraph,limit:Int = 4_096)
    throws -> (ids:Set<String>,visitedNodes:Int) {
    var ids=Set<String>(),visited=0
    for group in movedGroups where group.surface == surface {
      guard let local=group.localBounds(for:bounds) else { continue }
      let query=graph.visibleGroupCandidates(group.id,on:surface,in:local,limit:limit)
      guard !query.overflow else {
        throw CollaborationError("selection_limit","В этой области слишком много объектов.")
      }
      visited += query.visitedIndexNodes
      ids.formUnion(query.ids)
      guard ids.count <= limit else {
        throw CollaborationError("selection_limit","В этой области слишком много объектов.")
      }
    }
    return (ids,visited)
  }
}

extension NotebookAppModel {
  func spatialInteractionDelta(boardID:UUID,graph:NotebookGraphicGraph,
    baseGraph:NotebookGraphicGraph?)->NotebookSpatialInteractionDelta {
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
    var elements:[String:SpatialElement]=[:],excluded=Set<String>()
    var movedGroups:[NotebookSpatialInteractionDelta.MovedGroup]=[]
    if let board=boardHierarchy?.board(boardID) {
      for id in groups {
        guard let base=baseGraph?.placement(id),let current=graph.placement(id),base != current,
          let element=board.element(id:id) else { continue }
        movedGroups.append(.init(id:id,surface:element.surface,current:current))
      }
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
    return .init(ids:ids,elements:elements,excluded:excluded,movedGroups:movedGroups)
  }
}
