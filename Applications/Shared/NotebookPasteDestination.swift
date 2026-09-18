import Foundation
import NotebookCore

/// A captured physical owner, not a live selection that can change during paste.
struct NotebookPasteDestination: Identifiable, Hashable, Sendable {
  let target: CollaborationTarget
  let title: String
  let center: SpatialPoint
  let availableSize: SpatialPoint
  let worldOrigin: WorldPoint?
  var id: String { target.kind.rawValue + ":" + target.id.uuidString }
  func offset(for fragment: NotebookPasteFragment) -> SpatialPoint {
    .init(x:center.x-fragment.size.x/2,y:center.y-fragment.size.y/2)
  }
}

extension NotebookAppModel {
  var pasteDestination: NotebookPasteDestination? {
    guard case .ready = loadState, let presence, presencePhase == .settled else { return nil }
    switch presence.mode {
    case .board:
      return .init(target:.init(kind:.board,id:presence.boardID),
        title:workspace?.items.first { $0.id == presence.boardID }?.title ?? "Пространство",
        center:.zero,availableSize:.init(x:presence.viewport.x/presence.camera.scale,y:presence.viewport.y/presence.camera.scale),worldOrigin:presence.camera.center)
    case .page:
      guard let id = presence.notebookPageID, let page = pages[id] else { return nil }
      let title = workspace?.items.first { $0.id == presence.focusedItemID }?.title ?? "Тетрадь"
      let index = presence.focusedItemID.flatMap { notebookPageIndex(id,in:$0) }.map { " · лист \($0+1)" } ?? ""
      return .init(target:.init(kind:.page,id:id),title:title+index,
        center:.init(x:page.size.width/2,y:page.size.height/2),availableSize:.init(x:page.size.width,y:page.size.height),worldOrigin:nil)
    case .cover:
      guard let id = presence.focusedItemID else { return nil }
      let geometry = itemGeometry(id)
      return .init(target:.init(kind:.cover,id:id,boardID:presence.boardID),
        title:(workspace?.items.first { $0.id == id }?.title ?? "Тетрадь")+" · обложка",
        center:.init(x:geometry.width/2,y:geometry.height/2),availableSize:.init(x:geometry.width,y:geometry.height),worldOrigin:nil)
    case .document: return nil
    }
  }

  /// The Mac can paste while the iPad is offline. The visible owner is an
  /// explicit option; an unavailable page never silently redirects a paste.
  var pasteDestinations: [NotebookPasteDestination] {
    var destinations = pasteDestination.map { [$0] } ?? []
    if let root = workspace?.rootBoardID, !destinations.contains(where:{$0.target.kind == .board && $0.target.id == root}) {
      destinations.append(.init(target:.init(kind:.board,id:root),title:"Пространство",
        center:.zero,availableSize:.init(x:834,y:1194),worldOrigin:.zero))
    }
    return destinations
  }
}
