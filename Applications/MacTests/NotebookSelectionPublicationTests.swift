import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class NotebookSelectionPublicationTests: XCTestCase {
  func testIPadContextReachesAgentIPCWithin100msWithoutMovingOrRenderingTheMac() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root: root), model = fixture.model
    retainNotebookUntilTeardown(model, removing: root)
    try await fixture.start(showingPage: true)
    model.setSelectionSurfaceActive(true)
    let local = try XCTUnwrap(model.presence), header = try fixture.store.workspaceHeader()
    let peer = NotebookTransportIdentity(deviceID: UUID(), workspaceID: header.workspaceID, displayName: "iPad")
    let connection = UUID(), session = UUID(), surface = CollaborationTarget(kind: .board, id: header.rootBoardID)
    model.peerConnected(peer, generation: connection)
    defer { model.peerDisconnected(peerID: peer.deviceID, generation: connection) }
    var times: [Double] = []
    for sequence in 1...10 {
      let remote = SessionPresence(boardID: header.rootBoardID, mode: .board,
        camera: .init(center: .init(x: Double(sequence) * 100, y: 120), scale: 0.3), viewport: .init(x: 834, y: 1194))
      let selected = NotebookSelection(id: UUID(), kind: .element, surface: surface, target: surface,
        elementID: "ipad-\(sequence)")
      XCTAssertTrue(selected.isValid)
      let start = ContinuousClock.now
      model.receivePeerTransient(.presence(.init(sessionID: session, sequence: UInt64(sequence),
        phase: .settled, presence: remote)), peerID: peer.deviceID, generation: connection)
      model.receivePeerTransient(.selection(.init(deviceID: peer.deviceID, sessionID: session,
        sequence: UInt64(sequence), selection: selected)), peerID: peer.deviceID, generation: connection)
      // No finishPendingPersistence or Mac preview readiness before timing the
      // agent's real socket read. Queueing and disk publication count as delay.
      let observed = try await fixture.read(.init(kind: .presence)).decode(SessionPresence.self)
      let choice = try await fixture.read(.init(kind: .selection)).decode(NotebookSelectionSnapshot.self)
      let elapsed = start.duration(to: .now)
      times.append(Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
      XCTAssertEqual(observed, remote); XCTAssertEqual(choice.selection, selected)
      XCTAssertEqual(choice.deviceID, peer.deviceID)
      XCTAssertLessThanOrEqual(elapsed, .milliseconds(100), "iPad context → Mac writer → actual agent IPC")
      XCTAssertEqual(model.presence, local, "Prioritising the iPad must not steal the Mac's independent camera")
    }
    let sorted = times.sorted()
    let evidence = XCTAttachment(string: "iPad transient admission → real Mac IPC, not radio/LLM timing.\n"
      + "samplesMs=\(times), p50Ms=\(sorted[4]), p95Ms=\(sorted[9]), maxMs=\(sorted[9])")
    evidence.name = "ipad-context-to-agent-ipc"; evidence.lifetime = .keepAlways; add(evidence)
  }

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
