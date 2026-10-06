import CryptoKit
import Foundation
import NotebookCore
import XCTest
@testable import Notebook

final class NotebookPreviewPublicationTests: XCTestCase {
  @MainActor
  func testStaleReceiptRefusesOnlyItsOwnSlotAndPreservesTheAcceptedTail() async throws {
    try await fixture { store, queue, actor, workspace, page in
      let presence = SessionPresence(boardID: workspace.rootBoardID, mode: .page,
        camera: .init(), viewport: .init(x: 100, y: 140), focusedItemID: workspace.selectedItemID,
        openProgress: 1, selectedItemID: workspace.selectedItemID, notebookPageID: page.id)
      try store.savePresence(presence)
      let identity = try PreviewSourceIdentity.read(store, presence: presence)
      let header = try store.workspaceHeader(), hash = String(repeating: "0", count: 64)
      let receipt = CurrentViewReceipt(workspaceStamp: header.stamp,
        boardRevision: try XCTUnwrap(header.boardRevision), spatialInkStamp: try XCTUnwrap(header.spatialInkStamp),
        presence: presence, renderViewport: presence.viewport,
        surface: .page(itemID: workspace.selectedItemID, revision: .init(page: page), snapshotPNG_SHA256: hash), pngSHA256: hash)
      XCTAssertTrue(receipt.isValid)
      let originalReceipt = try JSONEncoder().encode(receipt)
      try originalReceipt.write(to: store.currentViewRevisionURL)
      let movedPresence = presence.replacingCamera(.init(center: .init(x: 10, y: 10), scale: 2))
      XCTAssertEqual(movedPresence.previewPixelIdentity, presence.previewPixelIdentity,
        "Page pixels stay fitted while receipt camera metadata advances")
      let publication = NotebookPreviewPublication<CurrentViewPublicationFiles?>()
      let result = NotebookPersistenceFenceContract.Signal<Result<Void, Error>>()
      queue.enqueueCommand(writesStore: true, { store in
        var edited = page
        _ = edited.replaceElements([.init(id: "new-source", kind: .web,
          frame: .init(x: 10, y: 10, width: 20, height: 20), source: "new", html: "<b>new</b>")], actor: actor)
        try store.savePage(edited)
        try store.savePresence(movedPresence)
      }, completion: { _ in })
      queue.enqueueCommand(writesStore: true, { store in
        try CurrentViewPreviewWriter.refreshReceipt(store: store, presence: movedPresence,
          identity: identity, dependencies: nil, permit: publication)
      }, completion: { result.set($0) })
      let tail = store.root.appendingPathComponent("accepted-tail")
      queue.enqueueCommand(writesStore: true, { _ in try Data("saved".utf8).write(to: tail) }, completion: { _ in })
      let drained = await queue.flush()
      XCTAssertTrue(drained, queue.failure ?? "")
      XCTAssertNil(queue.failure)
      XCTAssertEqual(queue.pendingCount, 0)
      guard case .failure(let error) = result.value else { return XCTFail("Stale publication must return its refusal") }
      XCTAssertEqual((error as? CollaborationError)?.code, "snapshot_changed")
      XCTAssertEqual(try Data(contentsOf: store.currentViewRevisionURL), originalReceipt)
      XCTAssertEqual(try String(contentsOf: tail, encoding: .utf8), "saved")
      XCTAssertEqual(try store.loadPage(page.id).elements.map(\.id), ["new-source"])
    }
  }

  @MainActor
  func testRevocationBeforeAdmissionDoesNotBlockLaterAcceptedWork() async throws {
    try await fixture { store, queue, _, _, _ in
      let publication = NotebookPreviewPublication<CurrentViewPublicationFiles?>()
      let result = NotebookPersistenceFenceContract.Signal<Result<Void, Error>>()
      let prepared = NotebookPersistenceFenceContract.Signal<Bool>()
      publication.revoke()
      queue.enqueueCommand(writesStore: true, { _ in
        try publication.publish(preparing: { prepared.set(true); return nil }, writing: { try $0?.write() })
      }, completion: { result.set($0) })
      let tail = store.root.appendingPathComponent("accepted-tail")
      queue.enqueueCommand(writesStore: true, { _ in try Data("saved".utf8).write(to: tail) }, completion: { _ in })
      let drained = await queue.flush()
      XCTAssertTrue(drained, queue.failure ?? "")
      XCTAssertNil(prepared.value)
      guard case .failure(let error) = result.value else { return XCTFail("Revocation must return its refusal") }
      XCTAssertEqual((error as? CollaborationError)?.code, "snapshot_cancelled")
      XCTAssertEqual(try String(contentsOf: tail, encoding: .utf8), "saved")
    }
  }

  @MainActor
  func testPartialFilePublicationRetriesTheExactAdmittedBytesAfterRevocation() async throws {
    try await fixture { store, queue, _, _, _ in
      let pngURL = store.root.appendingPathComponent("previews/retry.png")
      let receiptURL = store.root.appendingPathComponent("previews/retry.json")
      // A nonempty directory makes the real atomic receipt replacement fail,
      // after the first member of the publication pair has already been written.
      try FileManager.default.createDirectory(at: receiptURL, withIntermediateDirectories: true)
      try Data("held".utf8).write(to: receiptURL.appendingPathComponent("held"))
      let files = CurrentViewPublicationFiles(png: (Data("original pixels".utf8), pngURL),
        receipt: Data("original receipt".utf8), receiptURL: receiptURL)
      let publication = NotebookPreviewPublication<CurrentViewPublicationFiles>()
      let preparationCount = NotebookPersistenceFenceContract.Signal<Int>()
      let completed = NotebookPersistenceFenceContract.Signal<Bool>()
      queue.enqueueCommand(writesStore: true, { _ in
        try publication.publish(preparing: {
          let count = (preparationCount.value ?? 0) + 1; preparationCount.set(count)
          guard count == 1 else { throw CollaborationError("snapshot_changed", "Source changed after admission") }
          return files
        }, writing: { try $0.write() })
      }, completion: { if case .success = $0 { completed.set(true) } })
      let tail = store.root.appendingPathComponent("accepted-tail")
      queue.enqueueCommand(writesStore: true, { _ in try Data("saved".utf8).write(to: tail) }, completion: { _ in })
      let failed = await queue.flush()
      XCTAssertFalse(failed)
      XCTAssertNotNil(queue.failure)
      XCTAssertEqual(queue.pendingCount, 2)
      XCTAssertNil(completed.value)
      XCTAssertFalse(FileManager.default.fileExists(atPath: tail.path))
      XCTAssertEqual(try Data(contentsOf: pngURL), files.png?.data)
      publication.revoke()
      try FileManager.default.removeItem(at: receiptURL)
      queue.retry()
      let saved = await queue.flush()
      XCTAssertTrue(saved, queue.failure ?? "")
      XCTAssertEqual(preparationCount.value, 1)
      XCTAssertEqual(completed.value, true)
      XCTAssertEqual(try Data(contentsOf: pngURL), files.png?.data)
      XCTAssertEqual(try Data(contentsOf: receiptURL), files.receipt)
      XCTAssertEqual(try String(contentsOf: tail, encoding: .utf8), "saved")
      XCTAssertEqual(queue.pendingCount, 0)
    }
  }

  @MainActor
  func testTargetReceiptRetriesItsAdmittedFingerprintAfterPartialPublication() async throws {
    try await fixture { store, queue, _, _, page in
      let request = try store.requestTargetRender(target: .init(kind: .page, id: page.id),
        expectedRevision: page.agentStamp.revision, region: .init(x: 0, y: 0, width: 50, height: 70))
      let png = Data("retained target pixels".utf8)
      let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
      let fingerprint = try store.regionalFingerprint(request, inkFingerprint: hash)
      let receipt = TargetRenderReceipt(request: request, status: "ready", pngSHA256: hash,
        referenceFingerprint: fingerprint, pixelSize: .init(x: 100, y: 140))
      let receiptURL = store.targetReceiptURL(request.id)
      try FileManager.default.createDirectory(at: receiptURL, withIntermediateDirectories: true)
      try Data("held".utf8).write(to: receiptURL.appendingPathComponent("held"))
      let publication = NotebookPreviewPublication<TargetRenderReceipt>()
      let preparationCount = NotebookPersistenceFenceContract.Signal<Int>()
      queue.enqueueCommand(writesStore: true, { store in
        try publication.publish(preparing: {
          let count = (preparationCount.value ?? 0) + 1; preparationCount.set(count)
          guard count == 1 else { throw CollaborationError("snapshot_changed", "Source changed after admission") }
          return receipt
        }, writing: { try store.saveTargetRender($0, png: png) })
      }, completion: { _ in })
      let failed = await queue.flush()
      XCTAssertFalse(failed)
      XCTAssertNotNil(queue.failure)
      XCTAssertEqual(try Data(contentsOf: store.targetPNGURL(request.id)), png)
      publication.revoke()
      try FileManager.default.removeItem(at: receiptURL)
      queue.retry()
      let saved = await queue.flush()
      XCTAssertTrue(saved, queue.failure ?? "")
      XCTAssertEqual(preparationCount.value, 1)
      let persisted = try XCTUnwrap(store.loadTargetRenderReceipt(request.id))
      XCTAssertEqual(persisted, receipt, "Retry preserves the regional proof and original completion time")
      XCTAssertEqual(try Data(contentsOf: store.targetPNGURL(request.id)), png)
    }
  }

  @MainActor
  private func fixture(_ body: (NotebookStore, NotebookPersistenceQueue, UUID, WorkspaceIndex, PageDocument) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-preview-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let (workspace, pages) = try store.loadOrCreate(actor: actor, pageSize: .init(width: 100, height: 140))
    _ = try store.loadOrCreateSpatialInk(actor: actor)
    let page = try XCTUnwrap(pages[try XCTUnwrap(workspace.selectedPageID)])
    try await body(store, NotebookPersistenceQueue(store: store), actor, workspace, page)
  }
}
