#if os(iOS)
import NotebookCore
import UIKit

/// Frozen source identity of one physical cover, independent of its neighbors.
@MainActor
struct NotebookCoverPresentedSources: Equatable {
  let boardID: UUID
  let revision: CoverRenderingRevision
  let installedInkRevision: String?

  static func current(model: NotebookAppModel, itemID: UUID, boardID: UUID) -> Self? {
    guard let presence = model.presence, presence.boardID == boardID,
      let cohort = model.compositionTiles.published,
      let sceneIndex = model.sceneIndex,
      cohort.plan.allowsLive(.item(itemID), in: .board(boardID)),
      model.presentedItem(id: itemID, cohort: cohort, presence: presence) != nil,
      let item = model.workspace?.item(id: itemID), item.kind != .board else { return nil }
    // The installed cohort can deliberately keep old pixels while a newer
    // source is loading. It cannot also decide that the source is current.
    // The native owner separately proves it installed this exact revision.
    return .init(boardID: boardID,
      revision: .init(item: item, geometry: model.itemGeometry(itemID),
        elements: sceneIndex.coverElements(itemID: itemID, boardID: boardID), journal: model.spatialInk),
      installedInkRevision: model.compositionTiles.surfaceRegistry.installedSource(on: .cover(itemID))?.journalRevision)
  }
}

/// Native owners register weakly. A shared cover address is not permission to
/// select an arbitrary duplicate or an offscreen portal presentation.
@MainActor
final class NotebookCoverPresentationRegistry {
  private final class WeakOwner {
    weak var value: IPadCoverOpeningController?
    init(_ value: IPadCoverOpeningController) { self.value = value }
  }
  private var owners: [UUID: [ObjectIdentifier: WeakOwner]] = [:]

  func register(_ owner: IPadCoverOpeningController, itemID: UUID) {
    owners[itemID, default: [:]][ObjectIdentifier(owner)] = WeakOwner(owner)
  }
  func remove(_ owner: IPadCoverOpeningController, itemID: UUID) {
    owners[itemID]?[ObjectIdentifier(owner)] = nil
    if owners[itemID]?.isEmpty == true { owners[itemID] = nil }
  }
  private func owner(itemID: UUID) -> IPadCoverOpeningController? {
    let live = owners[itemID]?.values.compactMap(\.value) ?? []
    return live.count == 1 ? live[0] : nil
  }
  func capture(itemID: UUID, expected: NotebookCoverPresentedSources, region: PageRect,
    resources: SceneRenderResources) throws -> NotebookSubmittedPixels? {
    guard let owner = owner(itemID: itemID) else { throw SceneRenderError.snapshotPending("cover_owner_unavailable") }
    return try owner.capturePresented(expected: expected, region: region, resources: resources)
  }
  func captureFailure(itemID: UUID, expected: NotebookCoverPresentedSources) -> String? {
    guard let owner = owner(itemID: itemID) else { return "cover_owner_unavailable" }
    return owner.presentationFailure(expected: expected)
  }
}
#endif
