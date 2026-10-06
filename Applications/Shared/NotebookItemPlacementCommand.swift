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

/// Native item commands retain their captured causal sources. Their Core
/// execution allowance uses the same bytes, including SQL, receipt and inverse
/// preparation; a small placement need not occupy a whole history reserve.
enum NotebookItemWriteAllowance {
  static let maximumCost = NotebookPersistenceAdmission.Cost(payloadBytes: 32 * 1_024 * 1_024,
    completionBytes: 160 * 1_024 * 1_024)
  static let sourceReadMaximumCost = NotebookPersistenceAdmission.Cost(payloadBytes: 8 * 1_024 * 1_024,
    completionBytes: 32 * 1_024 * 1_024)

  static func placementReservationCost(captured: [WorkspacePlacement], operationCount: Int,
    summary: String) throws -> NotebookPersistenceAdmission.Cost {
    guard (1...10).contains(captured.count), (1...2).contains(operationCount),
      summary.utf8.count <= maximumCost.payloadBytes else { throw limit() }
    do {
      var meter = try PlacementMeter(sourceCapacity: captured.count * 4,
        operationCount: operationCount, summary: summary)
      for source in captured {
        let original = try source.writeFootprint(), authored = try source.authoredResultWriteBound()
        try meter.add(retained: source.retainedPayloadBytes, footprint: original)
        // A preceding accepted drop returns this authored source or an
        // unchanged captured row. Neither can introduce unseen peer actors.
        try meter.add(retained: max(source.retainedPayloadBytes, authored.retainedBytes),
          footprint: .init(wireBytes: max(original.wireBytes, authored.footprint.wireBytes),
            tokens: max(original.tokens, authored.footprint.tokens)))
      }
      return try meter.cost()
    } catch NotebookStorageError.limitExceeded { throw limit() }
  }

  static func placementCost(captured: [WorkspacePlacement], resolved: [WorkspacePlacement] = [],
    operations: [CollaborationOperation] = [], summary: String = "") throws -> NotebookPersistenceAdmission.Cost {
    guard captured.count <= 10, resolved.count <= 10, operations.count <= 2,
      summary.utf8.count <= maximumCost.payloadBytes else { throw limit() }
    do {
      var operationBytes = 0, operationWire = 0, operationTokens = 0
      for operation in operations {
        let retained = MemoryLayout<CollaborationOperation>.stride + (operation.id?.utf8.count ?? 0) * 2
          + JSONValue.object(operation.values).retainedPayloadBytes
        let footprint = try operation.nativePlacementWriteFootprint()
        guard retained <= PlacementMeter.operationRetainedBound,
          footprint.wireBytes <= 4_096, footprint.tokens <= 128 else { throw limit() }
        operationBytes += retained; operationWire += footprint.wireBytes; operationTokens += footprint.tokens
      }
      var meter = try PlacementMeter(sourceCapacity: captured.capacity + resolved.capacity,
        operationCount: operations.count, summary: summary,
        operationBytes: operationBytes, operationWire: operationWire, operationTokens: operationTokens)
      for source in captured { try meter.add(retained: source.retainedPayloadBytes, footprint: source.writeFootprint()) }
      for source in resolved { try meter.add(retained: source.retainedPayloadBytes, footprint: source.writeFootprint()) }
      return try meter.cost()
    } catch NotebookStorageError.limitExceeded { throw limit() }
  }

  private struct PlacementMeter {
    // The two native schemas contain only a UUID target, optional moving UUID,
    // one four-number center or a two-UUID array. These are schema bounds,
    // independent of any opaque closure or document body.
    static let operationRetainedBound = 4_096
    private var retained: Int
    private var wire: Int
    private var tokens: Int

    init(sourceCapacity: Int, operationCount: Int, summary: String,
      operationBytes: Int? = nil, operationWire: Int? = nil, operationTokens: Int? = nil) throws {
      retained = sourceCapacity * MemoryLayout<WorkspacePlacement>.stride + 4_096
        + (operationBytes ?? operationCount * Self.operationRetainedBound) + summary.utf8.count * 2
      guard retained <= maximumCost.payloadBytes else { throw limit() }
      wire = (operationWire ?? operationCount * 4_096) + summary.utf8.count * 6 + 1_024
      tokens = (operationTokens ?? operationCount * 128) + 64
    }

    mutating func add(retained bytes: Int, footprint: ContentFieldVersion.WriteFootprint) throws {
      guard bytes <= maximumCost.payloadBytes - retained else { throw limit() }
      retained += bytes; wire += footprint.wireBytes; tokens += footprint.tokens
    }

    func cost() throws -> NotebookPersistenceAdmission.Cost {
      let maximum = maximumCost.completionBytes
      guard wire <= maximum / 8, tokens <= (maximum - wire * 8) / 512 else { throw limit() }
      let decode = wire * 8 + tokens * 512
      // CAS visits <=2 groups, exact outputs <=10 groups, and each of <=2
      // changed rows refreshes <=10 affected items with <=6 source rows. The
      // projection, inverse and receipt roundtrips fit within64 passes of this
      // metadata schema. Every actual phase consumes one sticky Core allowance.
      // Its allocation share is80%; the credit also owns COW/codec buffers.
      guard decode <= maximum / 80, wire <= maximum / 640 else { throw limit() }
      let finish = max(8 * 1_024 * 1_024 + retained * 2 + wire * 4 + decode * 80, wire * 640)
      guard finish <= maximum else { throw limit() }
      return .init(payloadBytes: retained, completionBytes: finish)
    }
  }

  static func deletionSourceCost(placement: WorkspacePlacement, captured: WorkspacePlacement? = nil,
    title: String) throws -> NotebookPersistenceAdmission.Cost {
    let retained = placement.retainedPayloadBytes + (captured ?? placement).retainedPayloadBytes
      + title.utf8.count * 2 + 4_096
    guard retained <= sourceReadMaximumCost.payloadBytes else { throw limit() }
    return .init(payloadBytes: retained, completionBytes: sourceReadMaximumCost.completionBytes)
  }

  static func deletionCost(source: NotebookItemLifecycle, placement: WorkspacePlacement,
    loadedPageCount: Int) throws -> NotebookPersistenceAdmission.Cost {
    let retained = MemoryLayout<NotebookItemLifecycle>.stride + source.item.title.utf8.count * 2
      + source.revision.utf8.count * 2 + placement.retainedPayloadBytes * 2
      + loadedPageCount * (MemoryLayout<UUID>.stride + 48) + 4_096
    guard retained <= maximumCost.payloadBytes else { throw limit() }
    return .init(payloadBytes: retained, completionBytes: maximumCost.completionBytes)
  }

  static func limit() -> CollaborationError {
    .init("resource_limit", "Подготовка изменения превышает резерв 192 МиБ. Уменьшите действие.")
  }
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

  func itemMoveSource(_ id: UUID, boardID: UUID) -> NotebookItemMoveSource? {
    guard !isItemBeingDeleted(id), let canonical = boardHierarchy?.board(boardID) else { return nil }
    let sources = Dictionary(uniqueKeysWithValues: canonical.placementContactSources(of: id) { id in
      guard let command = itemPlacementCommands[id], command.boardID == boardID else { return nil }
      return command.pose(of: id)
    }.map { ($0.id, $0) })
    guard !sources.isEmpty else { return nil }
    let ids = Set(sources.keys)
    return .init(boardID: boardID, itemID: id, placements: sources,
      dependencies: itemPlacementCommands.filter { ids.contains($0.key) && $0.value.boardID == boardID })
  }

  func retireItemPlacementCommands(in state: NotebookSceneState) {
    for (id, command) in itemPlacementCommands {
      guard let accepted = command.accepted, accepted.cursor <= state.header.cursor,
        let expected = accepted.placements[id],
        let current = state.hierarchy.board(command.boardID)?.placements.first(where: { $0.id == id }),
        current.hasObserved(expected) else { continue }
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
