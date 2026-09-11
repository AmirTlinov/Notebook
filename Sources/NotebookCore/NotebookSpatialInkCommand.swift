import CryptoKit
import Foundation

/// A native contact publishes its immutable measurements once. Later causal
/// state changes address only that contact; they never carry another journal.
public enum NotebookSpatialInkCommand: Sendable {
  case append(SpatialInkAction, journalStamp: VersionStamp)
  case state(actionID: UUID, creationStamp: VersionStamp, isActive: Bool,
    stateStamp: VersionStamp, journalStamp: VersionStamp)

  public var expectedResult: NotebookSpatialInkResult {
    switch self {
    case .append(let action, let stamp):
      return .init(actionID: action.id, creationStamp: action.stamp, isActive: action.isActive,
        stateStamp: action.stateStamp, journalStamp: stamp)
    case .state(let id, let creation, let active, let state, let journal):
      return .init(actionID: id, creationStamp: creation, isActive: active, stateStamp: state, journalStamp: journal)
    }
  }
}

/// The accepted metadata reports a concurrent state or clock without returning
/// or reconstructing the archive's samples to the native persistence queue.
public struct NotebookSpatialInkResult: Equatable, Sendable {
  public let actionID: UUID
  public let creationStamp: VersionStamp
  public let isActive: Bool
  public let stateStamp: VersionStamp
  public let journalStamp: VersionStamp
}

struct SpatialInkActionHeader: Codable {
  let id: UUID
  let tool: SpatialInkTool
  let color: SpatialInkColor
  let stamp: VersionStamp
  var isActive: Bool
  var stateStamp: VersionStamp

  init(_ action: SpatialInkAction) {
    id = action.id; tool = action.tool; color = action.color; stamp = action.stamp
    isActive = action.isActive; stateStamp = action.stateStamp
  }

  var isValid: Bool {
    color.isValid && stamp.counter <= VersionStamp.maximumCounter
      && stateStamp.counter <= VersionStamp.maximumCounter && stateStamp >= stamp
  }
}

extension NotebookStore {
  /// One UUID, immutable spans and mutable causal metadata share the ordinary
  /// SQL commit/journal. An exact retry is a no-op, even after an ambiguous ACK.
  @discardableResult
  public func commitSpatialInk(_ command: NotebookSpatialInkCommand) throws -> NotebookSpatialInkResult {
    try publishSpatialInk(command, origin: .contact)
  }

  enum SpatialInkPublicationOrigin { case contact, replication }

  /// Replication retains measured history even after its cover was deleted;
  /// it cannot create that cover. A new local contact requires a live owner.
  @discardableResult
  func publishSpatialInk(_ command: NotebookSpatialInkCommand, origin: SpatialInkPublicationOrigin) throws -> NotebookSpatialInkResult {
    let expected = command.expectedResult
    guard expected.creationStamp.counter <= VersionStamp.maximumCounter,
      expected.stateStamp.counter <= VersionStamp.maximumCounter,
      expected.journalStamp.counter <= VersionStamp.maximumCounter,
      expected.stateStamp >= expected.creationStamp,
      expected.journalStamp >= expected.stateStamp else {
      throw NotebookStorageError.invalidTransaction("spatial ink clock")
    }
    if case .append(let action, _) = command, !action.isValid {
      throw NotebookStorageError.invalidTransaction("spatial ink action")
    }
    return try commandTransaction {
      let database = currentSQL!, file = "spatial-ink.json", rootAddress = "spatial-ink.json#"
      let address = rootAddress + "/actions/@" + expected.actionID.uuidString.lowercased()
      let previous = try storedFragments(address: address, descendants: false).first
      let storedRoot = try storedFragments(address: rootAddress, descendants: false).first
      let root = try storedRoot
        ?? NotebookRecordCodec.encode(.encode(SpatialInkJournal(stamp: expected.journalStamp)), file: file).first!
      guard root.value["format"] == .number(Double(SpatialInkJournal.formatVersion)),
        let oldClock = try root.value["stamp"]?.decode(VersionStamp.self),
        oldClock.counter <= VersionStamp.maximumCounter else { throw NotebookStorageError.corruptRecord(rootAddress) }
      let nextClock = max(oldClock, expected.journalStamp)
      var header: SpatialInkActionHeader
      var position: Int
      if let previous {
        header = try previous.value.decode(SpatialInkActionHeader.self)
        guard header.isValid, header.id == expected.actionID, header.stamp == expected.creationStamp else {
          throw NotebookStorageError.transactionConflict
        }
        position = previous.position
        if case .append(let action, _) = command {
          guard header.tool == action.tool, header.color == action.color else { throw NotebookStorageError.transactionConflict }
          let spans = try Self.spatialInkSpans(action.spans, actionAddress: address)
          let hash = SHA256.hash(data: try Self.storageEncoder.encode(spans)).map { String(format: "%02x", $0) }.joined()
          guard try database.rows("SELECT hash FROM records WHERE address=?", [.text(spans.address)]).first?[0].text == hash else {
            throw NotebookStorageError.transactionConflict
          }
        }
        if expected.stateStamp == header.stateStamp, expected.isActive != header.isActive {
          throw NotebookStorageError.transactionConflict
        }
        if expected.stateStamp > header.stateStamp {
          if origin == .contact, expected.isActive && !header.isActive {
            let surfaces = try database.rows("SELECT kind,owner_id FROM ink_surfaces WHERE address=?", [.text(address)]).map { row -> SurfaceID in
              guard let kind = row[0].text.flatMap(SurfaceKind.init(rawValue:)),
                let id = row[1].text.flatMap(UUID.init(uuidString:)) else { throw NotebookStorageError.corruptRecord(address) }
              return .init(kind: kind, ownerID: id)
            }
            guard !surfaces.isEmpty else { throw NotebookStorageError.corruptRecord(address) }
            try requireSpatialInkOwners(surfaces, database: database)
          }
          header.isActive = expected.isActive; header.stateStamp = expected.stateStamp
        }
      } else {
        guard case .append(let action, _) = command else {
          throw NotebookStorageError.invalidTransaction("spatial ink action is missing")
        }
        if origin == .contact { try requireSpatialInkOwners(action.spans.map(\.surface), database: database) }
        else { try requireSpatialInkOwners(action.spans.map(\.surface).filter { $0.kind == .codeFragment }, database: database) }
        header = .init(action)
        let last = try database.rows("SELECT position FROM records WHERE parent=? AND collection='actions' ORDER BY position DESC,member DESC LIMIT 1", [.text(rootAddress)]).first?[0].integer ?? -1
        guard last < Int64.max else { throw NotebookStorageError.limitExceeded("spatial ink sequence") }
        position = Int(last + 1)
        // The action header's index reads its own spans, so install those first.
        try writeFragment(Self.spatialInkSpans(action.spans, actionAddress: address), database: database)
      }
      let next = NotebookStoredFragment(address: address, file: file, parent: rootAddress, collection: "actions",
        member: expected.actionID.uuidString.lowercased(), position: position, value: try .encode(header),
        collections: [.init(path: ["spans"], kind: .value)])
      // No unchanged blob INSERT, no span publication for undo or an echo.
      if previous != next { try writeFragment(next, database: database) }
      let changedRoot = root.replacing(value: root.value.setting("stamp", try .encode(nextClock)))
      if storedRoot == nil || changedRoot != root { try writeFragment(changedRoot, database: database) }
      return .init(actionID: header.id, creationStamp: header.stamp, isActive: header.isActive,
        stateStamp: header.stateStamp, journalStamp: nextClock)
    }
  }

  private static func spatialInkSpans(_ spans: [SpatialInkSpan], actionAddress: String) throws -> NotebookStoredFragment {
    .init(address: actionAddress + "/spans", file: "spatial-ink.json", parent: actionAddress,
      collection: "spans", member: "", position: 0, value: try .encode(spans), collections: [])
  }

  private func requireSpatialInkOwners(_ surfaces: [SurfaceID], database: NotebookSQLConnection) throws {
    for surface in Set(surfaces) {
      guard let id = surface.ownerID, surface.isValid, surface.kind != .page else {
        throw NotebookStorageError.invalidTransaction("spatial ink owner")
      }
      let address: String
      switch surface.kind {
      case .board: address = "board.json#/boards/@" + id.uuidString.lowercased()
      case .cover: address = "workspace.json#/items/@" + id.uuidString.lowercased()
      case .codeFragment: address = codeFragmentFile(id) + "#"
      case .page: throw NotebookStorageError.invalidTransaction("page ink owner")
      }
      guard try !database.rows("SELECT 1 FROM records WHERE address=?", [.text(address)]).isEmpty else {
        throw CollaborationError("target_missing", "Физический владелец новых чернил уже удалён.")
      }
    }
  }
}
