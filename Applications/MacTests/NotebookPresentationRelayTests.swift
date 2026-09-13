import NotebookCore
import XCTest
@testable import Notebook

final class NotebookPresentationRelayTests: XCTestCase {
  @MainActor func testRetryReadsReceiptAndNeverRepeatsCameraOrSVG() throws {
    let relay = NotebookPresentationRelay(), peer = UUID(), session = UUID()
    relay.observe(.init(sessionID: session, sequence: 1, phase: .settled,
      presence: .init(mode: .board, camera: .init(), viewport: .init(x: 800, y: 600))), from: peer)
    var sent: [NotebookPresentationMessage] = []
    relay.send = { message, target in XCTAssertEqual(target, peer); sent.append(message) }
    let view = try XCTUnwrap(relay.handle(.init(command: .presentation))["view"]).decode(NotebookPresentationView.self)
    let id = UUID(), request = NotebookPresentationRequest(id: id, view: view, steps: [.init(camera: .init(scale: 1))])
    var command = NotebookCommand(command: .presentation); command.presentation = request
    let receipt = try relay.handle(command)
    XCTAssertEqual(try relay.handle(command), receipt)
    XCTAssertEqual(sent.count, 1)
    relay.receive(.init(id: id, status: .completed), from: UUID())
    XCTAssertEqual(try relay.handle(command), receipt, "A different computer cannot finish this show")
    relay.receive(.init(id: id, status: .completed), from: peer)
    XCTAssertEqual(try relay.handle(command).decode(NotebookPresentationReceipt.self).status, .completed)
    command.presentation = .init(id: UUID(), view: view, steps: request.steps)
    XCTAssertThrowsError(try relay.handle(command), "A consumed capability cannot replay a show with another ID")
    XCTAssertEqual(sent.count, 1)
  }

  @MainActor func testDisconnectAndHumanMotionInvalidatePresentationCapability() throws {
    let relay = NotebookPresentationRelay(), peer = UUID(), session = UUID()
    let presence = SessionPresence(mode: .board, camera: .init(), viewport: .init(x: 800, y: 600))
    relay.observe(.init(sessionID: session, sequence: 1, phase: .settled, presence: presence), from: peer)
    let view = try XCTUnwrap(relay.handle(.init(command: .presentation))["view"]).decode(NotebookPresentationView.self)
    relay.send = { _, _ in XCTFail("Stale view must never be sent") }
    var command = NotebookCommand(command: .presentation)
    command.presentation = .init(id: UUID(), view: view, steps: [.init(camera: .init(scale: 1))])
    relay.observe(.init(sessionID: session, sequence: 2, phase: .active, presence: presence), from: peer)
    XCTAssertThrowsError(try relay.handle(command))
    relay.observe(.init(sessionID: session, sequence: 3, phase: .settled, presence: presence), from: peer)
    relay.disconnect(peer)
    XCTAssertThrowsError(try relay.handle(command))
  }

  @MainActor func testActualIPCReadsUnavailablePresentationWithoutWritingOrMovingStoredCamera() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("presentation-ipc-\(UUID())")
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    try await fixture.start()
    let cursor = try fixture.store.currentChangeCursor(), presence = try fixture.store.loadPresence()
    let result = try await fixture.send(.init(command: .presentation))
    XCTAssertEqual(result["status"], .string("unavailable"))
    let peer = UUID(), session = UUID()
    fixture.model.presentationRelay.observe(.init(sessionID: session, sequence: 1, phase: .settled,
      presence: .init(mode: .board, camera: .init(), viewport: .init(x: 800, y: 600))), from: peer)
    let ready = try await fixture.send(.init(command: .presentation))
    let view = try XCTUnwrap(ready["view"]).decode(NotebookPresentationView.self)
    let id = UUID(), bounds = NotebookPresentationRegion(origin: .zero, width: 100, height: 100)
    var play = NotebookCommand(command: .presentation)
    play.presentation = .init(id: id, view: view, steps: [.init(camera: .init(scale: 1),
      svg: "<svg viewBox=\"0 0 100 100\"><circle cx=\"50\" cy=\"50\" r=\"20\"/></svg>", bounds: bounds)])
    let sent = try await fixture.send(play)
    XCTAssertEqual(sent["status"], .string("sent"), "The actual socket must admit the complete typed script")
    var cancel = NotebookCommand(command: .presentation); cancel.actionID = id; cancel.cancel = true
    let cancelling = try await fixture.send(cancel)
    XCTAssertEqual(cancelling["id"], sent["id"], "Cancellation crosses the same socket without inventing another show")
    fixture.model.presentationRelay.receive(.init(id: id, status: .interrupted), from: peer)
    let retry = try await fixture.send(play)
    XCTAssertEqual(retry["status"], .string("interrupted"))
    XCTAssertEqual(try fixture.store.currentChangeCursor(), cursor)
    XCTAssertEqual(try fixture.store.loadPresence(), presence)
  }
}
