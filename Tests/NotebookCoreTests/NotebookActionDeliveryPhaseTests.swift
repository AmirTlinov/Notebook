import Foundation
import Testing
@testable import NotebookCore

@Suite("Delivery acknowledges an exact saved action phase")
struct NotebookActionDeliveryPhaseTests {
  private struct Fixture {
    let store: NotebookStore
    let actor = UUID(), device = UUID()
    let target: CollaborationTarget
    init() throws {
      store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("notebook-delivery-\(UUID())"))
      let workspace = try store.loadOrCreate(actor: actor, pageSize: .init(width: 400, height: 600)).0
      target = .init(kind: .board, id: workspace.rootBoardID)
      _ = try store.loadOrCreateSpatialInk(actor: actor)
      _ = try store.applyCollaborationAction(.init(summary: "A real target", expected: [
        .init(target: target, revision: store.targetContentRevision(target: target))], operations: [
        .init(kind: .insertElement, target: target, id: "control", values: ["kind": .string("web"),
          "source": .string("<button>Value</button>"), "state": .number(0),
          "frame": try .encode(PageRect(x: 0, y: 0, width: 200, height: 80)),
          "worldOrigin": try .encode(WorldPoint.zero)])]), actor: actor)
    }
    func clean() { try? FileManager.default.removeItem(at: store.root) }
    func set(_ value: Int) throws -> CollaborationReceipt {
      try store.applyCollaborationAction(.init(summary: "A state contribution", expected: [
        .init(target: target, revision: store.targetContentRevision(target: target))], operations: [
        .init(kind: .setElementState, target: target, id: "control", values: ["state": .number(Double(value))])]), actor: actor)
    }
    func detail(_ action: CollaborationReceipt) throws -> JSONValue {
      var command = NotebookCommand(command: .actionDetails); command.actionID = action.id
      return try #require(NotebookCommandDispatcher(store: store).handle(command).array.first)
    }
    func receipt(_ action: CollaborationReceipt) throws -> DeviceActionReceipt {
      try #require(store.deviceActionReceipts(actionIDs: [action.id]).first)
    }
  }

  @Test func originalEmptyAndUndoEmptyRequireDifferentActualArrivals() throws {
    let f = try Fixture(); defer { f.clean() }
    let initial = try f.set(0)
    #expect(initial.revisions.isEmpty && initial.changes.isEmpty)
    try f.store.acknowledgeReceivedActions(deviceID: f.device)
    let first = try f.receipt(initial), originalVersion = try initial.deliveryVersion()
    #expect(first.actionVersion == originalVersion)
    let undo = try f.store.undoCollaborationAction(initial.id, actor: f.actor)
    #expect(undo.undo?.restored == 0 && undo.revisions.isEmpty)
    #expect(try undo.deliveryVersion() != originalVersion)
    #expect(try f.detail(undo)["publication"]?["receivedByIPad"] == .string("awaiting_device"))
    #expect(try f.receipt(undo) == first, "A status read cannot invent a later arrival")
    try f.store.acknowledgeReceivedActions(deviceID: f.device)
    let second = try f.receipt(undo)
    #expect(second.actionVersion == (try undo.deliveryVersion()))
    #expect(second.receivedAt >= (try #require(undo.undo).completedAt))
    #expect(!second.displayComplete && second.shown.isEmpty && second.visibleRegions.isEmpty)
    #expect(try f.detail(undo)["publication"]?["receivedByIPad"] == .string("confirmed"))
    #expect(try f.detail(undo)["publication"]?["shownOnIPad"] == .string("not_required"))
    let cursor = try f.store.currentChangeCursor()
    try f.store.acknowledgeReceivedActions(deviceID: f.device)
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.receipt(undo) == second)
  }

  @Test func lateOldPhaseCannotOverwriteOrUnionTheCurrentReceipt() throws {
    let f = try Fixture(); defer { f.clean() }
    let initial = try f.set(0)
    try f.store.acknowledgeReceivedActions(deviceID: f.device)
    let old = try f.receipt(initial)
    let undo = try f.store.undoCollaborationAction(initial.id, actor: f.actor)
    try f.store.acknowledgeReceivedActions(deviceID: f.device)
    let current = try f.receipt(undo), cursor = try f.store.currentChangeCursor()
    // A delayed owner-provided display claim; these Core bytes are not a visual test.
    let late = DeviceActionReceipt(id: old.id, deviceID: old.deviceID, receivedAt: Date().addingTimeInterval(60),
      revisions: old.revisions, actionVersion: old.actionVersion, shown: initial.revisions,
      displayComplete: true, visibleRegions: [.init(target: f.target, revision: try f.store.referenceRevision(target: f.target))])
    #expect(try !f.store.saveDeviceActionReceipt(late))
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.receipt(undo) == current)
    let envelope = try CollaborationEnvelope(actions: [undo], delivery: [current])
      .merging(.init(actions: [initial], delivery: [late]))
    #expect(envelope.delivery == [current])
    _ = try f.store.receiveCollaboration(.init(delivery: [late]))
    #expect(try f.receipt(undo) == current)
    #expect(try f.store.currentChangeCursor() == cursor)
  }

  @Test func writerRejectsWrongRevisionsEvenWithTheCurrentVersion() throws {
    let f = try Fixture(); defer { f.clean() }
    let action = try f.set(1)
    #expect(!action.revisions.isEmpty)
    let counterfeit = DeviceActionReceipt(id: action.id, deviceID: f.device,
      revisions: [], actionVersion: try action.deliveryVersion(), displayComplete: true)
    let cursor = try f.store.currentChangeCursor()
    #expect(try !f.store.saveDeviceActionReceipt(counterfeit))
    #expect(try f.store.deviceActionReceipts(actionIDs: [action.id]).isEmpty)
    #expect(try f.store.currentChangeCursor() == cursor)
  }

  @Test func historicalVersionlessReceiptsStayReadableButCannotConfirmCurrent() throws {
    let f = try Fixture(); defer { f.clean() }
    let action = try f.set(1)
    #expect(action.requestFingerprint == nil, "No raw request fingerprint may be invented")
    let legacy = DeviceActionReceipt(id: action.id, deviceID: f.device, revisions: action.revisions,
      shown: action.revisions, displayComplete: true, visibleRegions: [.init(target: f.target, revision: try f.store.referenceRevision(target: f.target))])
    let file = "collaboration/delivery/\(action.id.uuidString.lowercased()).json"
    let encoded = try JSONValue.encode(legacy)
    #expect(encoded["actionVersion"] == nil)
    try f.store.publishRecords(writes: [file: encoded]) // Existing historical data, not the current ACK API.
    let before = try f.store.storedData(file), cursor = try f.store.currentChangeCursor()
    let read = try f.detail(action)
    #expect(read["publication"]?["receivedByIPad"] == .string("awaiting_device"))
    #expect(read["publication"]?["shownOnIPad"] == .string("awaiting_display"))
    #expect(read["delivery"]?.array.first?["sameActionVersion"] == .bool(false))
    #expect(try f.store.storedData(file) == before && f.store.currentChangeCursor() == cursor)
    #expect(try !f.store.saveDeviceActionReceipt(legacy))
    try f.store.acknowledgeReceivedActions(deviceID: f.device)
    let fresh = try f.receipt(action)
    #expect(fresh.actionVersion == (try action.deliveryVersion()))
    #expect(!fresh.displayComplete && fresh.shown.isEmpty && fresh.visibleRegions.isEmpty)
    #expect(try f.store.collaborationAction(action.id).requestFingerprint == nil)
    let undo = try f.store.undoCollaborationAction(action.id, actor: f.actor)
    #expect(undo.undo?.restored == 1)
    #expect(try f.store.readSpatialElement(boardID: f.target.id, elementID: "control")?.state == .number(0))
  }

  @Test func canonicalVersionSurvivesEncodingAndChangesWithTheSavedOutcome() throws {
    let f = try Fixture(); defer { f.clean() }
    let action = try f.set(1), version = try action.deliveryVersion()
    let roundTrip = try JSONValue.encode(action).decode(CollaborationReceipt.self)
    #expect(try roundTrip.deliveryVersion() == version)
    #expect(try f.store.collaborationAction(action.id).deliveryVersion() == version)
    let undo = try f.store.undoCollaborationAction(action.id, actor: f.actor)
    #expect(try undo.deliveryVersion() != version)
    let retry = try f.store.undoCollaborationAction(action.id, actor: f.actor)
    #expect(try retry.deliveryVersion() == undo.deliveryVersion())
  }

  private func synchronize(_ source: NotebookStore, _ destination: NotebookStore, peerID: UUID) throws {
    var cursor = try destination.peerCursor(peerID: peerID, direction: .incoming)
    while let change = try source.changeJournal(after: cursor).first {
      while true {
        let hashes = try destination.missingBlobHashes(for: change)
        if hashes.isEmpty { break }
        for hash in hashes {
          let size = try source.blobSize(hash: hash)
          var data = Data()
          while Int64(data.count) < size {
            data += try source.readBlobChunk(hash: hash, offset: Int64(data.count), maxBytes: 1_048_576)
          }
          try destination.stageBlob(data: data, expectedHash: hash)
        }
      }
      cursor = try destination.applyRemoteChange(change, peerID: peerID)
    }
  }

  @Test func realReplicationOfALateAckKeepsTheCurrentUndoArrival() throws {
    let f = try Fixture(); defer { f.clean() }
    let initial = try f.set(0)
    let peer = NotebookStore(root: f.store.root.appendingPathComponent("peer"))
    try peer.prepareEmptyWorkspace(workspaceID: f.store.workspaceHeader().workspaceID)
    try synchronize(f.store, peer, peerID: f.actor)
    let remoteInitial = try peer.collaborationAction(initial.id)
    #expect(try remoteInitial.deliveryVersion() == initial.deliveryVersion())
    // The peer is still on the original phase and legitimately queues its ACK.
    let late = DeviceActionReceipt(id: initial.id, deviceID: f.device,
      receivedAt: Date().addingTimeInterval(60), revisions: remoteInitial.revisions,
      actionVersion: try remoteInitial.deliveryVersion(), displayComplete: true)
    #expect(try peer.saveDeviceActionReceipt(late))
    let undo = try f.store.undoCollaborationAction(initial.id, actor: f.actor)
    try f.store.acknowledgeReceivedActions(deviceID: f.device)
    let current = try f.receipt(undo)
    try synchronize(peer, f.store, peerID: f.device)
    #expect(try f.receipt(undo) == current)
    #expect(try f.store.collaborationAction(initial.id) == undo)
    #expect(!current.displayComplete)
    #expect(try f.detail(undo)["publication"]?["receivedByIPad"] == .string("confirmed"))
  }
}
