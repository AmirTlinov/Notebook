import Foundation
import Testing
import NotebookCore
@testable import NotebookScriptHost

@MainActor
@Suite("Script observation read ownership")
struct NotebookScriptReaderTests {
  private actor Reader {
    private let session: NotebookReadSession
    private let entered: AsyncStream<Void>.Continuation
    private let release: DispatchSemaphore
    private var holdsNext = true

    init(store: NotebookStore, entered: AsyncStream<Void>.Continuation, release: DispatchSemaphore) {
      session = NotebookReadSession(store: store); self.entered = entered; self.release = release
    }

    func observe(_ operation: @Sendable (NotebookQueryCut) throws -> JSONValue) throws -> JSONValue {
      try session.observe { cut in
        let cursor = try cut.currentReadCursor(), result = try operation(cut)
        if holdsNext {
          holdsNext = false; entered.yield(())
          guard release.wait(timeout: .now() + 5) == .success else {
            throw CollaborationError("test_timeout", "The held observation was not released")
          }
          #expect(try cut.currentReadCursor() == cursor, "A writer cannot replace this observer's SQL cut")
        }
        return result
      }
    }
  }

  @Test func heldObservationKeepsItsCutWhileTheWriterCommitsAndTheNextReadSeesThatCommit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("script-query-cut-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let pageID = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194), initialPageID: pageID)
    var page = try store.loadPage(pageID)
    let frame = PageRect(x: 0, y: 0, width: 100, height: 100)
    page.replaceElements([.init(id: "addressed", kind: .markdown, frame: frame,
      source: "first cut", html: "<p>first cut</p>")], actor: actor)
    try store.savePage(page)
    let (events, entered) = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0), reader = Reader(store: store, entered: entered, release: release)
    let host = NotebookScriptCoordinator(command: { _ in throw CollaborationError("unexpected_command", "Observe uses the typed reader") },
      reader: { try await reader.observe($0) },
      persistence: { _ in throw CollaborationError("unexpected_write", "Pure observation cannot enter persistence") }, workingDirectory: root)
    let args = JSONValue.object(["target": try .encode(CollaborationTarget(kind: .page, id: pageID)),
      "elementID": .string("addressed")])
    let timeout = Task {
      do { try await Task.sleep(for: .seconds(5)); entered.finish(); release.signal() }
      catch { }
    }
    defer { timeout.cancel(); entered.finish(); release.signal() }
    let first = Task { try await host.context(.init(method: "observe", arguments: args)) }
    var iterator = events.makeAsyncIterator()
    let observed: Void? = await iterator.next()
    _ = try #require(observed, "The real SQL observer must enter before the competing writer")
    page.replaceElements([.init(id: "addressed", kind: .markdown, frame: frame,
      source: "second cut", html: "<p>second cut</p>")], actor: actor)
    try store.savePage(page)
    release.signal()
    let previous = try await first.value
    let current = try await host.context(.init(method: "observe", arguments: args))
    #expect(previous["data"]?["objects"]?.arrayValues.first?["value"]?["content"]?["source"] == .string("first cut"))
    #expect(current["data"]?["objects"]?.arrayValues.first?["value"]?["content"]?["source"] == .string("second cut"))
    #expect(previous["cursor"] != current["cursor"])
    await host.shutdown()
  }
}
