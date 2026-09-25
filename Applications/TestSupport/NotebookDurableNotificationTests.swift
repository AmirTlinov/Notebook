import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookDurableNotificationTests: XCTestCase {
  func testPeerDisconnectRetiresLocalBarriersWithoutWakingDurableDelivery() async throws {
    let (model, queue) = try await fixture()
    let prior = queue.onCommit
    var commits = 0
    queue.onCommit = { owner in commits += 1; prior?(owner) }
    let cursor = try model.store.currentChangeCursor(), peer = UUID(), generation = UUID()
    model.peerConnected(.init(deviceID: peer, workspaceID: try model.store.workspaceHeader().workspaceID,
      displayName: "Local barrier peer"), generation: generation)
    let activity = NotebookInputActivity(deviceID: peer, sessionID: UUID(), sequence: 1,
      targets: [.init(kind: .board, id: try model.store.workspaceHeader().rootBoardID)])
    model.receivePeerTransient(.inputActivity(activity), peerID: peer, generation: generation)
    model.peerDisconnected(peerID: peer, generation: generation)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    XCTAssertFalse(model.peerInputIsActive)
    XCTAssertFalse(try model.store.inputActivities().contains { $0.deviceID == peer })
    XCTAssertNotEqual(try model.store.readSelectionPublication().deviceID, peer)
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor)
    XCTAssertEqual(commits, 0, "Connection retirement changes local barriers, not shared content")
  }

  func testRealCommandEffectsNotifyOnlyForSharedContent() async throws {
    let (model, queue) = try await fixture()
    let prior = queue.onCommit
    var commits = 0
    queue.onCommit = { owner in commits += 1; prior?(owner) }
    let page = try XCTUnwrap(model.activePage), target = CollaborationTarget(kind: .page, id: page.id)
    let revision = try model.store.targetContentRevision(target: target)
    let cursor = try model.store.currentChangeCursor()
    let raw = CollaborationAction(summary: "Typed command notification", expected: [
      .init(target: target, revision: revision)], operations: [
        .init(kind: .insertElement, target: target, id: "notification-shape", values: [
          "kind": .string("graphic"), "source": .string(""),
          "frame": try .encode(PageRect(x: 20, y: 30, width: 80, height: 60)),
          "graphic": try .encode(NotebookGraphic(shape: .rectangle))])])
    var admit = NotebookCommand(command: .admitAction); admit.action = raw
    let admitted = try await execute(admit, model: model, queue: queue)
    let fingerprint = try XCTUnwrap(admitted["fingerprint"]).decode(String.self)
    XCTAssertEqual(admitted["state"], .string("reserved"))
    XCTAssertEqual(try model.store.prepareCollaborationSubmission(raw.id, fingerprint: fingerprint).action.id, raw.id)
    var render = NotebookCommand(command: .render)
    render.target = target; render.expectedRevision = revision
    _ = try await execute(render, model: model, queue: queue)
    var vision = NotebookCommand(command: .pageVision)
    vision.target = target; vision.expectedRevision = page.drawingStamp.revision
    _ = try await execute(vision, model: model, queue: queue)
    var placement = NotebookCommand(command: .placement)
    placement.placement = .init(target: target, expectedRevision: revision,
      items: [.init(id: "proposed", size: .init(width: 80, height: 60))])
    _ = try await execute(placement, model: model, queue: queue)
    let localSaved = await queue.flush(); XCTAssertTrue(localSaved)
    XCTAssertFalse(try model.store.targetRenderRequests().isEmpty, "The request was really stored")
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor)
    XCTAssertEqual(commits, 0, "Admission and render/placement requests are not durable publications")

    var commit = NotebookCommand(command: .commitAction)
    commit.action = raw; commit.fingerprint = fingerprint
    _ = try await execute(commit, model: model, queue: queue)
    let contentSaved = await queue.flush(); XCTAssertTrue(contentSaved)
    XCTAssertNotNil(try model.store.readPageElement(pageID: page.id, elementID: "notification-shape"))
    XCTAssertGreaterThan(try model.store.currentChangeCursor(), cursor)
    XCTAssertEqual(commits, 1, "A real accepted content edit must still wake delivery")

    var point = NotebookCommand(command: .point)
    point.references = [.init(target: target, revision: try model.store.referenceRevision(target: target), label: "Shared point")]
    _ = try await execute(point, model: model, queue: queue)
    let pointSaved = await queue.flush(); XCTAssertTrue(pointSaved)
    XCTAssertEqual(commits, 2, "Point appends shared context rather than a local selection request")
  }

  func testLoadedProgramStateNotifiesItsRealWriteButNotTheIdenticalReceipt() async throws {
    let (model, queue) = try await fixture()
    var page = try XCTUnwrap(model.activePage)
    let element = AgentElement(id: "notification-program", kind: .web,
      frame: .init(x: 0, y: 0, width: 160, height: 120), source: "State notification",
      html: "<output>State</output>")
    XCTAssertTrue(page.replaceElements([element], actor: model.actorID))
    try model.store.savePage(page)
    await model.reloadExternalChanges()?.value
    let settled = await queue.flush(); XCTAssertTrue(settled)
    let before = try XCTUnwrap(model.pages[page.id]?.programStateBasis(element.id))
    let cursor = try model.store.currentChangeCursor()
    let prior = queue.onCommit
    var commits = 0
    queue.onCommit = { owner in commits += 1; prior?(owner) }
    func commit(_ basis: NotebookProgramStateBasis) async -> NotebookProgramStateBasis? {
      await withCheckedContinuation { done in
        let admitted = model.commitElementState(pageID: page.id, elementID: element.id, state: .number(1),
          onCommitted: .init(sourceBasis: basis) { done.resume(returning: $0) })
        if !admitted { done.resume(returning: nil) }
      }
    }
    let firstResult = await commit(before)
    let first = try XCTUnwrap(firstResult)
    let written = await queue.flush(); XCTAssertTrue(written)
    XCTAssertNotEqual(first, before)
    XCTAssertEqual(first, model.pages[page.id]?.programStateBasis(element.id),
      "An exact optimistic receipt is still a new durable state")
    XCTAssertEqual(try model.store.readPageElement(pageID: page.id, elementID: element.id)?.state, .number(1))
    let after = try model.store.currentChangeCursor()
    XCTAssertGreaterThan(after, cursor)
    XCTAssertEqual(commits, 1, "The actual state edit must wake durable delivery")
    let repeated = await commit(first)
    let drained = await queue.flush(); XCTAssertTrue(drained)
    XCTAssertEqual(repeated, first, "The identical event still receives the addressed source/state check")
    XCTAssertEqual(try model.store.currentChangeCursor(), after)
    XCTAssertEqual(commits, 1, "A no-op receipt must not wake delivery a second time")
  }

  func testCoalescingCannotCrossTypedPeerOrCommandFences() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root); try store.prepare()
    let queue = NotebookPersistenceQueue(store: store), owner = NotebookPersistenceQueue.Owner.fileDraft("same")
    let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
    let third = root.appendingPathComponent("third")
    // These are all admitted in one MainActor segment, before drain can start.
    queue.enqueue(owner: owner) { _ in try Data().write(to: first); return false }
    queue.enqueue(owner: .peerSession(UUID())) { _ in
      XCTAssertTrue(FileManager.default.fileExists(atPath: first.path)); return false
    }
    queue.enqueue(owner: owner) { _ in try Data().write(to: second); return false }
    queue.enqueueCommand(owner: .command(.read), { _ in
      XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }, completion: { result in if case .failure(let error) = result { XCTFail(String(describing: error)) } })
    queue.enqueue(owner: owner) { _ in try Data().write(to: third); return false }
    let saved = await queue.flush(); XCTAssertTrue(saved)
    XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: third.path))
  }

  private func execute(_ command: NotebookCommand, model: NotebookAppModel,
    queue: NotebookPersistenceQueue) async throws -> JSONValue {
    #if os(macOS)
      // Includes the actual Mac adapter; its classification must not use changesStore.
      return try await model.executeLocalCommand(command)
    #else
      // iPad has no local MCP server, but uses the same writer and Core command owner.
      return try await queue.submit(owner: .command(command.command)) { try NotebookCommandDispatcher(store: $0).handle(command) }
    #endif
  }

  private func fixture() async throws -> (NotebookAppModel, NotebookPersistenceQueue) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root), queue = NotebookPersistenceQueue(store: store)
    let model = NotebookAppModel(store: store, startsNearbySync: false, persistenceQueue: queue)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let ready = await model.finishPendingPersistence(); XCTAssertTrue(ready)
    return (model, queue)
  }
}
