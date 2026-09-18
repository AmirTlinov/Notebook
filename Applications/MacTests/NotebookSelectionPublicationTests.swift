import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class NotebookSelectionPublicationTests: XCTestCase {
  func testAuthenticatedSelectionUsesWriterAndIPCAndRetiredConnectionsCannotResurrectIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root: root), model = fixture.model
    retainNotebookUntilTeardown(model, removing: root)
    try await fixture.start()
    let header = try fixture.store.workspaceHeader()
    let peer = NotebookTransportIdentity(deviceID: UUID(), workspaceID: header.workspaceID, displayName: "iPad")
    let connection = UUID(), session = UUID(), surface = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let selected = NotebookSelection(id: UUID(), kind: .elements, surface: surface, target: surface, elementIDs: ["node", "connection"])
    func send(_ sequence: UInt64, _ selection: NotebookSelection?, generation: UUID) {
      model.receivePeerTransient(.selection(.init(deviceID: peer.deviceID, sessionID: session,
        sequence: sequence, selection: selection)), peerID: peer.deviceID, generation: generation)
    }
    model.peerConnected(peer, generation: connection)
    send(1, selected, generation: connection)
    await model.finishPendingPersistence()
    let first = try await fixture.read(.init(kind: .selection)).decode(NotebookSelectionSnapshot.self)
    XCTAssertEqual(first.selection, selected)
    let cleared = NotebookSelection(id: UUID(), kind: .empty, surface: surface)
    send(2, cleared, generation: connection); send(1, selected, generation: connection)
    await model.finishPendingPersistence()
    let second = try await fixture.read(.init(kind: .selection)).decode(NotebookSelectionSnapshot.self)
    XCTAssertEqual(second.selection, cleared)
    model.peerDisconnected(peerID: peer.deviceID, generation: connection)
    send(3, selected, generation: connection)
    await model.finishPendingPersistence()
    let disconnected = try await fixture.read(.init(kind: .selection)).decode(NotebookSelectionSnapshot.self)
    XCTAssertEqual(disconnected.status, "unknown")
    let next = UUID()
    model.peerConnected(peer, generation: next)
    send(4, selected, generation: next)
    model.peerDisconnected(peerID: peer.deviceID, generation: connection)
    await model.finishPendingPersistence()
    let current = try await fixture.read(.init(kind: .selection)).decode(NotebookSelectionSnapshot.self)
    XCTAssertEqual(current.selection, selected)
    model.peerDisconnected(peerID: peer.deviceID, generation: next)
  }
}
