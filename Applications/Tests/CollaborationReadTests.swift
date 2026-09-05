import NotebookCore
import XCTest
@testable import Notebook

final class CollaborationReadTests: XCTestCase {
  @MainActor
  func testHistoryReadsDoNotPrepareContentAndInvalidateAfterHumanChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
    let page = try XCTUnwrap(model.activePage)
    let target = CollaborationTarget(kind: .page, id: page.id)
    let action = try model.store.applyCollaborationAction(.init(summary: "Пояснение",
      expected: [.init(target: target, revision: page.agentStamp.revision)], operations: [
        .init(kind: .insertElement, target: target, id: "idea", values: ["kind": .string("markdown"),
          "source": .string("Idea"), "html": .string("Idea"), "frame": .object([
            "x": .number(30), "y": .number(30), "width": .number(200), "height": .number(80)])])]), actor: UUID())
    await model.reloadExternalChanges()?.value
    let reference = try XCTUnwrap(action.resultReferences(in: XCTUnwrap(model.collaborationContent)).first)
    let finger = UUID()
    model.inputGate.beginContact(source: finger)
    await model.refreshCollaborationDetails()
    XCTAssertFalse(model.collaborationDetailsAreCurrent)
    let clock = ContinuousClock(), began = clock.now
    for _ in 0..<100 {
      XCTAssertTrue(model.results(for: action).isEmpty)
      XCTAssertTrue(model.continuations(for: action).isEmpty)
      XCTAssertEqual(model.referenceStatusLabel(reference), "Проверяется исходник")
    }
    XCTAssertLessThan(began.duration(to: clock.now), .milliseconds(100), "Строки не ждут сериализации, файлов или замка")
    model.inputGate.endContact(source: finger)
    for _ in 0..<100 where model.inputGate.isActive { await Task.yield() }
    await model.refreshCollaborationDetails()
    XCTAssertTrue(model.collaborationDetailsAreCurrent)
    XCTAssertEqual(model.results(for: action).first?.region?.x, 30)

    var changed = try model.store.loadPage(page.id)
    _ = changed.replaceElements([.init(id: "idea", kind: .markdown,
      frame: .init(x: 130, y: 30, width: 200, height: 80), source: "Human", html: "Human")], actor: model.actorID)
    model.receivePeerMessage(.page(changed))
    await model.finishPendingPersistence()
    XCTAssertFalse(model.collaborationDetailsAreCurrent)
    XCTAssertTrue(model.results(for: action).isEmpty, "Старое положение не выдаётся за текущий результат")
    await model.refreshCollaborationDetails()
    XCTAssertEqual(model.results(for: action).first?.region?.x, 130)
    XCTAssertTrue(model.continuations(for: action).contains { $0.author == .human })
  }
}
