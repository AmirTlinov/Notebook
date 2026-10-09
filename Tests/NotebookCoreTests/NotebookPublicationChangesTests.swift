import Foundation
import Synchronization
import Testing
@testable import NotebookCore

@Suite("Postcommit publication uses the local merge journal")
struct NotebookPublicationChangesTests {
  private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("publication-" + UUID().uuidString)
    let actor = UUID(), itemID = UUID(), pageID = UUID()
    let store: NotebookStore
    init() throws {
      store = .init(root: root)
      _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194),
        initialNotebookID: itemID, initialPageID: pageID)
    }
    func insert(_ id: String) throws {
      let target = CollaborationTarget(kind: .page, id: pageID)
      _ = try store.applyNativeElementEdits([.init(kind: .insertElement, target: target, id: id,
        values: ["kind": .string("nativeText"), "source": .string(id),
          "frame": try .encode(PageRect(x: 10, y: 10, width: 100, height: 40))])],
        summary: "Write page", sources: [store.readNativeElementSource(target: target, id: id)], actor: actor)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
  }

  @Test func aSmallPageEditAddressesOnlyItsOwnerAndMetadata() throws {
    let f = try Fixture(); defer { f.clean() }
    let before = try f.store.currentChangeCursor()
    try f.insert("one")
    let changes = try NotebookReadSession(store: f.store).observe { try $0.readPublicationChanges(after: before) }
    #expect(changes.header.cursor > before)
    #expect(changes.header.cursor == (try f.store.currentChangeCursor()))
    #expect(changes.pages == [f.pageID])
    #expect(changes.documents.isEmpty && changes.documentStates.isEmpty)
    #expect(!changes.sceneChanged && !changes.needsOwnerRead)
    #expect(changes.metadataChanged)
    let unchanged = try f.store.readPublicationChanges(after: changes.header.cursor)
    #expect(unchanged.pages.isEmpty && !unchanged.sceneChanged && !unchanged.metadataChanged)
  }

  @Test func highWaterAndAddressesStayInTheSameSnapshotWhileAnotherWriterCommits() throws {
    let f = try Fixture(); defer { f.clean() }
    let before = try f.store.currentChangeCursor()
    try f.insert("one")
    let first = try f.store.currentChangeCursor()
    let other = NotebookStore(root: f.root)
    let reader = NotebookReadSession(store: f.store)
    let result = Mutex<Result<Void, any Error>?>(nil), done = DispatchSemaphore(value: 0)
    try reader.observe { cut in
      #expect(try cut.currentChangeCursor() == first)
      DispatchQueue.global(qos: .userInitiated).async {
        let written = Result<Void, any Error> {
          let target = CollaborationTarget(kind: .page, id: f.pageID)
          _ = try other.applyNativeElementEdits([.init(kind: .insertElement, target: target, id: "two",
            values: ["kind": .string("nativeText"), "source": .string("two"),
              "frame": try .encode(PageRect(x: 20, y: 20, width: 100, height: 40))])],
            summary: "Concurrent write", sources: [other.readNativeElementSource(target: target, id: "two")], actor: UUID())
        }
        result.withLock { $0 = written }; done.signal()
      }
      try #require(done.wait(timeout: .now() + 10) == .success)
      try #require(result.withLock { $0 }).get()
      let changes = try cut.readPublicationChanges(after: before)
      #expect(changes.header.cursor == first)
      #expect(changes.pages == [f.pageID])
    }
    #expect(try f.store.currentChangeCursor() > first)
    #expect(try reader.observe { try $0.readPublicationChanges(after: first) }.pages == [f.pageID])
  }

  @Test func aTruncatedDeltaRequiresAnOwnerReadInsteadOfInferringAbsence() throws {
    let f = try Fixture(); defer { f.clean() }
    let before = try f.store.currentChangeCursor()
    try f.insert("one")
    let limited = try f.store.readPublicationChanges(after: before, limit: 1)
    #expect(limited.needsOwnerRead)
    #expect(limited.header.cursor == (try f.store.currentChangeCursor()))
  }
}
