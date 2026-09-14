import Foundation

/// An addressed navigation read is independent of the camera's bounded scene
/// cache. Placement and physical size come from the same current SQL snapshot;
/// document bodies and program state are not needed to find their owner.
public enum NotebookReferenceLocation: Sendable, Equatable {
  case board(id: UUID, center: WorldPoint, region: PageRect)
  case item(boardID: UUID, id: UUID, center: WorldPoint, geometry: WorkspaceItemGeometry)
}

extension NotebookStore {
  public func readReferenceLocation(_ reference: CollaborationReference) throws -> NotebookReferenceLocation {
    try readTransaction { store in
      let target = reference.target
      let missing = CollaborationError("reference_unavailable", "Место больше недоступно.", target: target)
      switch target.kind {
      case .board:
        guard try store.readBoardNodeHeader(target.id) != nil else { throw missing }
        var origin = reference.worldOrigin ?? .zero
        var region = reference.region ?? .init(x: -400, y: -300, width: 800, height: 600)
        if let elementID = reference.elementID {
          guard let element = try store.readSpatialElement(boardID: target.id, elementID: elementID) else { throw missing }
          origin = element.worldOrigin ?? .zero
          region = .init(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height)
        }
        guard region.width > 0, region.height > 0,
          let center = origin.addressOffset(x: region.x + region.width / 2, y: region.y + region.height / 2)
        else { throw missing }
        return .board(id: target.id, center: center, region: region)
      case .cover, .document, .page:
        let itemID: UUID
        if target.kind == .page {
          guard let owner = try store.ownerItemID(ofPage: target.id),
            try store.resolveNotebookPage(target.id, in: owner) != nil else { throw missing }
          itemID = owner
        } else { itemID = target.id }
        guard let header = try store.readItemHeader(itemID),
          let placement = try store.readBoardItem(itemID),
          let center = placement.board.focusedCenter(of: itemID), center.isValid,
          target.kind != .document || header.kind == .document else { throw missing }
        let geometry: WorkspaceItemGeometry
        if header.kind == .document {
          guard let paper = try store.readDocumentPaperSize(itemID) else { throw missing }
          geometry = .document(paper)
        } else { geometry = .notebook }
        return .item(boardID: placement.id, id: itemID, center: center, geometry: geometry)
      case .workspace, .codeFragment:
        throw CollaborationError("invalid_reference_navigation", "Этот адрес не является местом на доске.", target: target)
      }
    }
  }
}
