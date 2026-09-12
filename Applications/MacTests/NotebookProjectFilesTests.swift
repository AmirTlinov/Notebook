import XCTest
import NotebookCore
@testable import Notebook

private final class WaitingFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
  let presentedItemURL: URL?
  let presentedItemOperationQueue: OperationQueue = {
    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; return queue
  }()
  let entered: XCTestExpectation
  let gate = DispatchSemaphore(value: 0)
  init(url: URL, entered: XCTestExpectation) { presentedItemURL = url; self.entered = entered }
  func relinquishPresentedItem(toWriter writer: @escaping @Sendable ((@Sendable () -> Void)?) -> Void) {
    entered.fulfill(); gate.wait(); writer(nil)
  }
}

@MainActor
final class NotebookProjectFilesTests: XCTestCase {
  private func fixture(_ body: (NotebookStore, CodexProject, NotebookFileAddress, UUID, MacNotebookProjectFiles) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-files-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let projectRoot = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    let project = CodexProject(id: "real-project", name: "Code", roots: [projectRoot.path])
    let address = NotebookFileAddress(computer: UUID(), project: project.id, root: projectRoot.path, path: "main.py")
    let store = NotebookStore(root: root.appendingPathComponent("notebook")), author = UUID()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store)
    let files = MacNotebookProjectFiles(persistence: queue)
    defer { files.stop() }
    try await body(store, project, address, author, files)
    let saved = await queue.flush(); XCTAssertTrue(saved)
  }
  private func stage(_ edit: NotebookFileEdit, store: NotebookStore, author: UUID) throws -> UUID {
    let data = try JSONEncoder().encode(edit), id = UUID(), digest = NotebookFileVersion.hash(data)
    var offset = 0
    while offset < data.count {
      let end = min(data.count, offset + NotebookFileVersion.chunkBytes)
      _ = try store.stageFileUpload(.init(id: id, digest: digest, total: data.count, offset: offset, data: data.subdata(in: offset..<end)), author: author)
      offset = end
    }
    return id
  }
  private func fails<Value>(_ operation: () async throws -> Value, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await operation(); XCTFail("An unsafe or cancelled file operation succeeded", file: file, line: line) }
    catch { }
  }
  func testRealFileMergeConflictPermissionsAndRecoveryNeverRepeatWrites() async throws {
    try await fixture { store, project, address, author, files in
      let file = URL(fileURLWithPath: address.root).appendingPathComponent(address.path)
      try Data("a\nb\nc".utf8).write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
      let id = try stage(.init(address: address, base: "a\nb\nc", text: "A\nb\nc"), store: store, author: author)
      try Data("a\nb\nC".utf8).write(to: file)
      let result = try await files.commit(id, author: author, address: address, project: project)
      XCTAssertEqual(result.status, .saved)
      XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "A\nb\nC")
      XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o755)
      try Data("newer human content".utf8).write(to: file)
      let reconciled = try await files.reconcile(id, project: project); XCTAssertEqual(reconciled, result)
      await fails { try await files.commit(id, author: author, address: address, project: project) }
      XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "newer human content")
      let conflict = try stage(.init(address: address, base: "A\nb\nC", text: "A\nlocal\nC"), store: store, author: author)
      let conflicting = try await files.commit(conflict, author: author, address: address, project: project); XCTAssertEqual(conflicting.status, .conflict)
      XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "newer human content")
      XCTAssertEqual(try store.stagedFileEdit(conflict, author: author).text, "A\nlocal\nC")
    }
  }
  func testSymlinkEscapeRevokedRootAndDirectoryPagination() async throws {
    try await fixture { _, project, address, _, _ in
      let root = URL(fileURLWithPath: address.root), file = root.appendingPathComponent(address.path)
      try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.deletingLastPathComponent())
      XCTAssertThrowsError(try MacNotebookProjectFiles.read(address, project: project))
      let nested = address.child("secret")
      XCTAssertThrowsError(try MacNotebookProjectFiles.read(nested, project: project))
      XCTAssertThrowsError(try MacNotebookProjectFiles.read(address, project: .init(id: project.id, name: "revoked", roots: [])))
      for index in 0..<130 { try Data("code".utf8).write(to: root.appendingPathComponent(String(format: "%03d.py", index))) }
      let dir = NotebookFileAddress(computer: address.computer, project: address.project, root: address.root, path: "")
      let first = try MacNotebookProjectFiles.list(dir, project: project, after: nil)
      let second = try MacNotebookProjectFiles.list(dir, project: project, after: first.next)
      XCTAssertEqual(first.entries.count, 64); XCTAssertEqual(second.entries.count, 64)
      XCTAssertTrue(Set(first.entries.map(\.name)).isDisjoint(with: second.entries.map(\.name)))
    }
  }
  func testPreparedUnknownWriteOnlyReconcilesTheObservedHash() async throws {
    try await fixture { store, project, address, _, files in
      let file = URL(fileURLWithPath: address.root).appendingPathComponent(address.path), id = UUID()
      let old = Data("before".utf8), new = Data("after".utf8)
      try old.write(to: file); try store.prepareFileCommit(id, address: address, before: old, after: new)
      let unknown = try await files.reconcile(id, project: project); XCTAssertNil(unknown)
      XCTAssertEqual(try Data(contentsOf: file), old)
      try new.write(to: file)
      let reconciled = try await files.reconcile(id, project: project); XCTAssertEqual(reconciled?.status, .saved)
    }
  }
  func testRealRenameKeepsNotesAndNeverReplacesAnotherFileOrRepeatsTheMove() async throws {
    try await fixture { store, project, address, author, files in
      let root = URL(fileURLWithPath: address.root), file = root.appendingPathComponent(address.path)
      let bytes = Data("print(4)\n".utf8); try bytes.write(to: file)
      let fragment = NotebookCodeFragment(file: address, sourceHash: NotebookFileVersion.hash(bytes), utf16Offset: 0,
        text: "print(4)\n", width: 600, height: 100, fontSize: 15, stamp: .init(counter: 1, actor: author))
      let stroke = SpatialInkAction(tool: .pen, spans: [.init(surface: .codeFragment(fragment.id), samples: [
        .init(point: .init(x: 30, y: 20), timeOffset: 0, width: 3, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      ])], stamp: .init(counter: 2, actor: author))
      _ = try store.commitCodeInk(fragment: fragment, command: .append(stroke, journalStamp: stroke.stamp))
      let occupied = root.appendingPathComponent("occupied.py"); try Data("other owner".utf8).write(to: occupied)
      let rejected = NotebookFileRename(address: address, path: "occupied.py", version: .init(bytes), after: 0)
      await fails { try await files.rename(UUID(), request: rejected, project: project) }
      XCTAssertEqual(try Data(contentsOf: file), bytes)
      XCTAssertEqual(try String(contentsOf: occupied, encoding: .utf8), "other owner")
      let request = NotebookFileRename(address: address, path: "renamed.py", version: .init(bytes), after: 0), id = UUID()
      let renamed = try await files.rename(id, request: request, project: project); XCTAssertEqual(renamed, request)
      XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
      XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(request.path)), bytes)
      let note = try XCTUnwrap(store.codeAnnotation(fragment.id))
      XCTAssertEqual(note.fragment.file, address); XCTAssertEqual(note.fragment.currentFile, request.destination)
      XCTAssertEqual(note.fragment.text, fragment.text); XCTAssertEqual(note.ink.actions, [stroke])
      // Recreating the old path never makes it an alias for the renamed file.
      try Data("new unrelated file".utf8).write(to: file)
      let reconciled = try await files.reconcileRename(id, project: project); XCTAssertEqual(reconciled, request)
      await fails { try await files.rename(id, request: request, project: project) }
      XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new unrelated file")
      XCTAssertTrue(try store.codeFragments(file: address).isEmpty)
    }
  }
  func testRenameRejectsChangedContentEscapesAndRevokedRoot() async throws {
    try await fixture { store, project, address, _, files in
      let file = URL(fileURLWithPath: address.root).appendingPathComponent(address.path)
      let bytes = Data("old".utf8); try Data("new".utf8).write(to: file)
      let request = NotebookFileRename(address: address, path: "moved.py", version: .init(bytes), after: 0)
      await fails { try await files.rename(UUID(), request: request, project: project) }
      await fails { try await files.rename(UUID(), request: request, project: .init(id: project.id, name: "revoked", roots: [])) }
      XCTAssertFalse(NotebookFileRename(address: address, path: "../escape.py", version: .init(bytes), after: 0).isValid)
      XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
    }
  }

  func testInterruptedRenameIsReconciledByIdentityNotBySimilarTextOrAnotherMove() async throws {
    try await fixture { store, project, address, _, files in
      let root = URL(fileURLWithPath: address.root), file = root.appendingPathComponent(address.path)
      let bytes = Data("original".utf8); try bytes.write(to: file)
      let request = NotebookFileRename(address: address, path: "renamed.py", version: .init(bytes), after: 0), id = UUID()
      await fails { try await files.rename(id, request: request, project: project,
        afterMove: { throw CocoaError(.fileWriteUnknown) }) }
      XCTAssertEqual(try store.fileRename(id)?.completed, false)
      let moved = root.appendingPathComponent(request.path)
      // A subsequent ordinary write does not turn a proven rename into retry.
      let handle = try FileHandle(forWritingTo: moved); try handle.write(contentsOf: Data("changed!".utf8)); try handle.close()
      let coldQueue = NotebookPersistenceQueue(store: NotebookStore(root: store.root))
      let coldFiles = MacNotebookProjectFiles(persistence: coldQueue); defer { coldFiles.stop() }
      let reconciled = try await coldFiles.reconcileRename(id, project: project); XCTAssertEqual(reconciled, request)
      let saved = await coldQueue.flush(); XCTAssertTrue(saved)
      XCTAssertEqual(try store.fileRename(id)?.completed, true)
      XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
  }

  func testBlockedFileAccessDoesNotHoldPersistenceOrSpawnAnotherWorkerAndCannotWriteAfterStop() async throws {
    try await fixture { store, project, address, author, _ in
      let file = URL(fileURLWithPath: address.root).appendingPathComponent(address.path)
      try Data("original".utf8).write(to: file)
      let id = try stage(.init(address: address, base: "original", text: "changed"), store: store, author: author)
      let queue = NotebookPersistenceQueue(store: store)
      let entered = expectation(description: "filesystem is waiting"), released = expectation(description: "filesystem returned")
      let gate = DispatchSemaphore(value: 0)
      let files = MacNotebookProjectFiles(persistence: queue, timeout: .milliseconds(150), beforeAccess: {
        entered.fulfill(); gate.wait(); released.fulfill()
      })
      defer { files.stop(); gate.signal() }
      let pending = Task { try await files.commit(id, author: author, address: address, project: project) }
      await fulfillment(of: [entered], timeout: 2)
      // The same ordered writer accepts and reads a local draft while external
      // filesystem access is blocked; a second file call is not dispatched.
      var draft = NotebookFileDraft(address: address, text: "original"); draft.text = "local note"
      let savedInput = draft
      try await queue.submit { try $0.saveFileDraft(savedInput) }
      let savedDraft = try await queue.submit { try $0.fileDraft(address) }
      XCTAssertEqual(savedDraft?.text, "local note")
      await fails { try await pending.value }
      await fails { try await files.list(address, project: project, after: nil) }
      files.stop(); gate.signal()
      await fulfillment(of: [released], timeout: 2)
      let saved = await queue.flush(); XCTAssertTrue(saved)
      XCTAssertNil(try store.fileCommit(id))
      XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
      XCTAssertEqual(try store.fileDraft(address)?.text, "local note")
    }
  }

  func testStopAfterActualRenameLeavesDurableIntentAndColdReadbackCompletesItOnce() async throws {
    try await fixture { store, project, address, _, _ in
      let root = URL(fileURLWithPath: address.root), file = root.appendingPathComponent(address.path)
      let bytes = Data("preserved".utf8); try bytes.write(to: file)
      let queue = NotebookPersistenceQueue(store: store)
      let files = MacNotebookProjectFiles(persistence: queue)
      let moved = expectation(description: "real rename completed"), released = expectation(description: "returned after stop")
      let gate = DispatchSemaphore(value: 0), id = UUID()
      defer { files.stop(); gate.signal() }
      let request = NotebookFileRename(address: address, path: "moved.py", version: .init(bytes), after: 0)
      let pending = Task {
        try await files.rename(id, request: request, project: project, afterMove: {
          moved.fulfill(); gate.wait(); released.fulfill()
        })
      }
      await fulfillment(of: [moved], timeout: 2)
      let intent = try await queue.submit { try $0.fileRename(id) }; XCTAssertEqual(intent?.completed, false)
      files.stop(); await fails { try await pending.value }
      gate.signal(); await fulfillment(of: [released], timeout: 2)
      let saved = await queue.flush(); XCTAssertTrue(saved)
      XCTAssertEqual(try store.fileRename(id)?.completed, false)
      let coldQueue = NotebookPersistenceQueue(store: NotebookStore(root: store.root))
      let coldFiles = MacNotebookProjectFiles(persistence: coldQueue); defer { coldFiles.stop() }
      let result = try await coldFiles.reconcileRename(id, project: project); XCTAssertEqual(result, request)
      XCTAssertTrue(try XCTUnwrap(store.fileRename(id)).completed)
      XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
      XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(request.path)), bytes)
      let coldSaved = await coldQueue.flush(); XCTAssertTrue(coldSaved)
    }
  }

  func testWaitingNativeFilePresenterDoesNotHoldTheNotebookWriterAndStopCancelsCoordination() async throws {
    try await fixture { store, project, address, author, _ in
      let file = URL(fileURLWithPath: address.root).appendingPathComponent(address.path)
      try Data("before".utf8).write(to: file)
      let id = try stage(.init(address: address, base: "before", text: "after"), store: store, author: author)
      let entered = expectation(description: "native coordinator is waiting for another editor")
      let presenter = WaitingFilePresenter(url: file, entered: entered)
      NSFileCoordinator.addFilePresenter(presenter)
      defer { presenter.gate.signal(); NSFileCoordinator.removeFilePresenter(presenter) }
      let queue = NotebookPersistenceQueue(store: store)
      let files = MacNotebookProjectFiles(persistence: queue)
      defer { files.stop() }
      let pending = Task { try await files.commit(id, author: author, address: address, project: project) }
      await fulfillment(of: [entered], timeout: 3)
      let input = NotebookFileDraft(address: address, text: "independent draft")
      try await queue.submit { try $0.saveFileDraft(input) }
      let saved = await queue.flush(); XCTAssertTrue(saved)
      files.stop(); await fails { try await pending.value }
      XCTAssertNil(try store.fileCommit(id))
      XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "before")
      XCTAssertEqual(try store.fileDraft(address)?.text, input.text)
    }
  }

}
