import Foundation
import NotebookCore
import Observation

/// A contact retains the displayed item and complete source stack. A subsequent
/// accepted command may supply only its own saved result, never fresh peer state.
struct NotebookItemMoveSource: Sendable {
  let boardID: UUID
  let itemID: UUID
  let placements: [UUID: WorkspacePlacement]
  let dependencies: [UUID: NotebookItemPlacementCommand]
}

struct NotebookItemPlacementResult: Sendable {
  let cursor: UInt64
  let placements: [UUID: WorkspacePlacement]
  let header: BoardDocument
}

@MainActor @Observable
final class NotebookItemPlacementCommand {
  let id: UUID
  let boardID: UUID
  let poses: [UUID: WorkspacePlacementPose]
  @ObservationIgnored var task: Task<NotebookItemPlacementResult?, Never>!
  var accepted: NotebookItemPlacementResult?
  var rejected = false

  init(id: UUID, boardID: UUID, poses: [UUID: WorkspacePlacementPose]) {
    self.id = id; self.boardID = boardID; self.poses = poses
  }

  func pose(of id: UUID) -> WorkspacePlacementPose? {
    rejected ? nil : (accepted?.placements[id]?.pose ?? poses[id])
  }
}

extension NotebookAppModel {
  func acceptedPlacementBoard(_ board: BoardDocument, boardID: UUID) -> BoardDocument {
    guard !itemPlacementCommands.isEmpty else { return board }
    let poses = board.placements.reduce(into: [UUID: WorkspacePlacementPose]()) { result, source in
      guard let command = itemPlacementCommands[source.id], command.boardID == boardID else { return }
      result[source.id] = command.pose(of: source.id)
    }
    return poses.isEmpty ? board : board.projectingPlacementPoses(poses)
  }

  func itemMoveSource(_ id: UUID, boardID: UUID, shown: BoardDocument? = nil) -> NotebookItemMoveSource? {
    guard !isItemBeingDeleted(id), let canonical = boardHierarchy?.board(boardID) else { return nil }
    let board = shown ?? acceptedPlacementBoard(canonical, boardID: boardID)
    guard board.itemIDs.contains(id) else { return nil }
    let ids = Set(board.stack(containing: id)?.itemIDs ?? [id])
    let sources = Dictionary(uniqueKeysWithValues: board.placements.filter { ids.contains($0.id) }.map { ($0.id, $0) })
    return .init(boardID: boardID, itemID: id, placements: sources,
      dependencies: itemPlacementCommands.filter { ids.contains($0.key) && $0.value.boardID == boardID })
  }

  func retireItemPlacementCommands(through cursor: UInt64) {
    for (id, command) in itemPlacementCommands {
      guard let accepted = command.accepted, accepted.cursor <= cursor else { continue }
      itemPlacementCommands[id] = nil
    }
  }

  func itemMoveSourceIsCurrent(_ source: NotebookItemMoveSource) -> Bool {
    guard let board = boardHierarchy?.board(source.boardID) else { return false }
    for (id, original) in source.placements {
      let preceding = source.dependencies[id]
      if let current = itemPlacementCommands[id] {
        guard current.id == preceding?.id, !current.rejected else { return false }
      } else {
        let expected = preceding?.accepted?.placements[id] ?? original
        guard preceding == nil || preceding?.accepted != nil,
          board.placements.first(where: { $0.id == id }) == expected else { return false }
      }
    }
    return true
  }
}
