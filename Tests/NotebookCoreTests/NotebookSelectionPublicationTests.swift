import Foundation
import Testing
@testable import NotebookCore

@Suite struct NotebookSelectionPublicationTests {
  @Test func regionIsOneExplicitReadOnlySelection() throws {
    let target=CollaborationTarget(kind:.board,id:UUID())
    var value=NotebookSelection(id:UUID(),kind:.region,surface:target,target:target)
    value.region=[.init(x:10,y:20),.init(x:50,y:20),.init(x:30,y:70)]
    value.worldOrigin = .zero
    #expect(value.isValid)
    #expect(try JSONDecoder().decode(NotebookSelection.self,from:JSONEncoder().encode(value)) == value)
    value.elementID="competing-choice"
    #expect(!value.isValid)
  }

  @Test func regionPublicationPreserves8192PointsAndRejects8193WithoutReplacingSelection() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), device = UUID(), session = UUID(), connection = UUID()
    let header = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let target = CollaborationTarget(kind: .board, id: header.rootBoardID)
    var selection = NotebookSelection(id: UUID(), kind: .region, surface: target, target: target)
    selection.region = (0..<8192).map { index in
      let angle = Double(index) * 2 * Double.pi / 8192
      return SpatialPoint(x: 200 + 100 * cos(angle), y: 200 + 100 * sin(angle))
    }
    selection.worldOrigin = .zero
    let accepted = NotebookSelectionEnvelope(deviceID: device, sessionID: session, sequence: 1, selection: selection)
    let decoded = try JSONDecoder().decode(NotebookSelectionEnvelope.self, from: JSONEncoder().encode(accepted))
    #expect(decoded == accepted)
    try store.saveLocalSelectionPublication(decoded)
    #expect(try store.readSelectionPublication().selection == selection)
    try store.beginSelectionPublication(deviceID: device, connectionID: connection)
    #expect(try store.acceptSelectionPublication(decoded, connectionID: connection))
    #expect(try store.readSelectionPublication().selection == selection)

    selection.region?.append(.init(x: 301, y: 200))
    let overflow = NotebookSelectionEnvelope(deviceID: device, sessionID: session, sequence: 2, selection: selection)
    #expect(!overflow.isValid)
    #expect(throws: NotebookStorageError.self) { try store.saveLocalSelectionPublication(overflow) }
    #expect(throws: CollaborationError.self) { try store.acceptSelectionPublication(overflow, connectionID: connection) }
    #expect(try store.readSelectionPublication().selection == accepted.selection)
    try store.endSelectionPublication(deviceID: device, connectionID: connection)
    #expect(try store.readSelectionPublication().selection == accepted.selection)
  }

  @Test func connectionLifetimeOrdersClearAndRejectsLateOldProcess() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), device = UUID(), session = UUID(), connection = UUID()
    let header = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let readCursor = try store.currentReadCursor(), changeCursor = try store.currentChangeCursor()
    let surface = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let selected = NotebookSelection(id: UUID(), kind: .element, surface: surface, target: surface, elementID: "after-32")
    let first = NotebookSelectionEnvelope(deviceID: device, sessionID: session, sequence: 1, selection: selected)
    #expect(try store.readSelectionPublication().status == "unknown")
    #expect(try !store.acceptSelectionPublication(first, connectionID: connection))
    try store.beginSelectionPublication(deviceID: device, connectionID: connection)
    #expect(try store.acceptSelectionPublication(first, connectionID: connection))
    let empty = NotebookSelection(id: UUID(), kind: .empty, surface: surface)
    #expect(try store.acceptSelectionPublication(.init(deviceID: device, sessionID: session, sequence: 2, selection: empty), connectionID: connection))
    #expect(try !store.acceptSelectionPublication(first, connectionID: connection))
    #expect(try store.readSelectionPublication().selection == empty)
    #expect(try !store.acceptSelectionPublication(.init(deviceID: device, sessionID: UUID(), sequence: 3, selection: selected), connectionID: connection))
    #expect(try store.acceptSelectionPublication(.init(deviceID: device, sessionID: session, sequence: 3, selection: nil), connectionID: connection))
    let inactive = try store.readSelectionPublication()
    #expect(inactive.status == "unknown" && inactive.sessionID == session && inactive.generation == 3)
    #expect(inactive.selection == nil)
    #expect(try !store.acceptSelectionPublication(.init(deviceID: device, sessionID: session, sequence: 2, selection: empty), connectionID: connection))
    try store.endSelectionPublication(deviceID: device, connectionID: connection)
    #expect(try store.readSelectionPublication().status == "unknown")
    #expect(try !store.acceptSelectionPublication(first, connectionID: connection))
    let next = UUID()
    try store.beginSelectionPublication(deviceID: device, connectionID: next)
    #expect(try store.acceptSelectionPublication(.init(deviceID: device, sessionID: UUID(), sequence: 1, selection: selected), connectionID: next))
    try store.endSelectionPublication(deviceID: device, connectionID: connection)
    #expect(try store.readSelectionPublication().selection == selected)
    try store.resetSelectionPublication()
    #expect(try store.readSelectionPublication().status == "unknown")
    #expect(try store.currentReadCursor() == readCursor, "Session publication must not invalidate content continuations")
    #expect(try store.currentChangeCursor() == changeCursor, "A selection is not replicated content or an undoable action")
  }

  @Test func peerObservationNeverReplacesLocalNavigationAndDisconnectRestoresLocalSelection() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), localDevice = UUID(), peer = UUID(), connection = UUID(), session = UUID()
    let header = try store.initializeWorkspace(actor: localDevice, pageSize: .init(width: 834, height: 1194))
    let local = SessionPresence(boardID: header.rootBoardID, mode: .board,
      camera: .init(scale: 0.4), viewport: .init(x: 1100, y: 780))
    let remote = SessionPresence(boardID: header.rootBoardID, mode: .board,
      camera: .init(scale: 1.2), viewport: .init(x: 834, y: 1194))
    try store.savePresence(local)
    let selection = NotebookSelection(id: UUID(), kind: .empty, surface: .init(kind: .board, id: header.rootBoardID))
    try store.saveLocalSelectionPublication(.init(deviceID: localDevice, sessionID: UUID(), sequence: 1, selection: selection))
    let cursor = try store.currentChangeCursor(), read = try store.currentReadCursor()
    #expect(try store.readObservedPresenceIfAvailable() == local)
    #expect(try store.readSelectionPublication().selection == selection)
    try store.beginSelectionPublication(deviceID: peer, connectionID: connection)
    #expect(try store.readObservedPresenceIfAvailable() == nil)
    #expect(try store.readSelectionPublication().status == "unknown")
    let envelope = PresenceEnvelope(sessionID: session, sequence: 2, phase: .settled, presence: remote)
    #expect(try !store.acceptPresencePublication(envelope, deviceID: peer, connectionID: UUID()))
    #expect(try store.acceptPresencePublication(envelope, deviceID: peer, connectionID: connection))
    #expect(try !store.acceptPresencePublication(envelope, deviceID: peer, connectionID: connection))
    #expect(try !store.acceptPresencePublication(.init(sessionID: UUID(), sequence: 3, phase: .settled, presence: local), deviceID: peer, connectionID: connection))
    #expect(try store.loadPresence() == local)
    #expect(try store.readObservedPresenceIfAvailable() == remote)
    try store.endSelectionPublication(deviceID: peer, connectionID: UUID())
    #expect(try store.readObservedPresenceIfAvailable() == remote)
    try store.endSelectionPublication(deviceID: peer, connectionID: connection)
    #expect(try store.readObservedPresenceIfAvailable() == local)
    #expect(try store.readSelectionPublication().selection == selection)
    #expect(try store.currentChangeCursor() == cursor)
    #expect(try store.currentReadCursor() == read)
  }

  @Test func invalidPhysicalOwnerIsRejectedAndNilIsNotAnEmptyChoice() throws {
    let target = CollaborationTarget(kind: .cover, id: UUID())
    #expect(!NotebookSelection(id: UUID(), kind: .empty, surface: target).isValid)
    #expect(!NotebookSelection(id: UUID(), kind: .empty, surface: .init(kind: .codeFragment, id: UUID())).isValid)
    #expect(!NotebookSelection(id: UUID(), kind: .element, surface: .init(kind: .page, id: UUID()), elementID: "missing owner").isValid)
    let page = CollaborationTarget(kind: .page, id: UUID())
    #expect(!NotebookSelection(id: UUID(), kind: .context, surface: page).isValid)
    #expect(NotebookSelection(id: UUID(), kind: .context, surface: page, resolving: true).isValid)
    #expect(NotebookSelectionEnvelope(deviceID: UUID(), sessionID: UUID(), sequence: 1, selection: nil).isValid)
    #expect(!NotebookSelectionEnvelope(deviceID: UUID(), sessionID: UUID(), sequence: 0, selection: nil).isValid)
  }

  @Test func selectedSetIsExplicitBoundedAndRoundTrips() throws {
    let page = CollaborationTarget(kind:.page,id:UUID())
    func selected(_ ids: [String]) -> NotebookSelection {
      .init(id:UUID(),kind:.elements,surface:page,target:page,elementIDs:ids)
    }
    let valid = selected(["b","a"])
    #expect(valid.isValid)
    #expect(try JSONDecoder().decode(NotebookSelection.self,from:JSONEncoder().encode(valid)) == valid)
    for ids in [[],["a"],["a","a"],["a",""],(0..<33).map(String.init)] { #expect(!selected(ids).isValid) }
    #expect(!NotebookSelection(id:UUID(),kind:.element,surface:page,target:page,elementID:"a",elementIDs:["a","b"]).isValid)
  }

  @Test func authenticatedTransportCoalescesSelectionWithoutReplacingOtherTransients() throws {
    let peer = NotebookTransportIdentity(deviceID: UUID(), workspaceID: UUID(), displayName: "iPad")
    let session = UUID(), surface = CollaborationTarget(kind: .page, id: UUID())
    var outgoing = NotebookTransportOutgoing()
    for sequence in 1...100 {
      let value = NotebookSelectionEnvelope(deviceID: peer.deviceID, sessionID: session, sequence: UInt64(sequence),
        selection: .init(id: UUID(), kind: .empty, surface: surface))
      let transient = NotebookTransportTransient.selection(value)
      #expect(transient.isValid(from: peer))
      #expect(!transient.isValid(from: .init(deviceID: UUID(), workspaceID: peer.workspaceID, displayName: "other")))
      #expect(try JSONDecoder().decode(NotebookTransportTransient.self, from: JSONEncoder().encode(transient)) == transient)
      try outgoing.enqueue(.transient(transient))
    }
    let activity = NotebookInputActivity(deviceID: peer.deviceID, sessionID: session, sequence: 1, targets: [surface])
    try outgoing.enqueue(.transient(.inputActivity(activity)))
    #expect(outgoing.pendingCount == 2)
    #expect(try outgoing.takeNext()?.message == .transient(.inputActivity(activity)))
    guard case .transient(.selection(let delivered)) = try outgoing.takeNext()?.message else {
      Issue.record("Expected the one current selection"); return
    }
    #expect(delivered.sequence == 100)
    #expect(try outgoing.takeNext() == nil)
  }
}
