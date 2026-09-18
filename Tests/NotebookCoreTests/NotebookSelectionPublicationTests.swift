import Foundation
import Testing
@testable import NotebookCore

@Suite struct NotebookSelectionPublicationTests {
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
