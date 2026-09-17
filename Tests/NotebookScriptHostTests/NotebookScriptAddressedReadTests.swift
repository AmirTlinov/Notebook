import Foundation
import Testing
@testable import NotebookCore
@testable import NotebookScriptHost

@MainActor
@Suite("Addressed script reads", .serialized)
struct NotebookScriptAddressedReadTests {
  @MainActor private final class Owner {
    let store: NotebookStore
    let pageID: UUID
    init() throws {
      store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("script-addressed-\(UUID())"))
      let index = try store.loadOrCreate(actor: UUID(), pageSize: .init(width: 834, height: 1194)).0
      pageID = try #require(index.selectedPageID)
      _ = try store.loadOrCreateSpatialInk(actor: UUID())
      var page = try store.loadPage(pageID)
      let changed = page.replaceElements((0..<40).map { .init(id: "element-\($0)", kind: .markdown,
        frame: .init(x: 0, y: 0, width: 100, height: 100), source: "source-\($0)", html: "<p>\($0)</p>") }, actor: UUID())
      #expect(changed)
      try store.savePage(page)
      try store.savePresence(.init(boardID: index.rootBoardID, mode: .page, camera: .init(),
        viewport: .init(x: 834, y: 1194), focusedItemID: index.selectedItemID, openProgress: 1,
        selectedItemID: index.selectedItemID, notebookPageID: pageID))
    }
    func host() -> NotebookScriptCoordinator {
      NotebookScriptCoordinator(command: { try await self.command($0) }, persistence: { try await self.persist($0) },
        workingDirectory: store.root.appendingPathComponent("derived/script-runtime"))
    }
    func command(_ request: NotebookCommand) throws -> JSONValue { try NotebookCommandDispatcher(store: store).handle(request) }
    func persist(_ operation: @Sendable (NotebookStore) throws -> JSONValue) throws -> JSONValue { try operation(store) }
    func poison(_ id: String) throws {
      try store.commandTransaction {
        try store.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=(SELECT hash FROM records WHERE address=?)",
          [.blob(Data("unrequested body must not decode".utf8)), .text(pageFile(pageID) + "#/elements/@" + id)])
      }
    }
  }

  @Test func explicitElementAfterPreviewLimitDoesNotReadSiblings() async throws {
    let owner = try Owner(), host = owner.host()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    try owner.poison("element-0")
    let args: JSONValue = .object(["target": try .encode(CollaborationTarget(kind: .page, id: owner.pageID)),
      "elementID": .string("element-39")])
    let value = try await host.context(.init(method: "observe", arguments: args))
    #expect(value["content"]?["element"]?["id"] == .string("element-39"))
    #expect(value["content"]?["element"]?["source"] == .string("source-39"))
    #expect(value["content"]?["agentRevision"] != nil)
    let direct = try await host.read(method: "page", arguments: .object(["id": .string(owner.pageID.uuidString), "elementID": .string("element-39")]))
    #expect(direct["values"]?.array.first?["element"]?["id"] == .string("element-39"))
  }

  @Test func repeatObservationChecksVersionsBeforeBodies() async throws {
    let owner = try Owner(), host = owner.host()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let first = try await host.context(.init(method: "observe"))
    #expect(first["content"]?["truncated"] == .bool(true))
    try owner.poison("element-0")
    let repeated = try await host.context(.init(method: "observe", arguments: .object(["since": try #require(first["changeKeys"])])))
    #expect(repeated["content"]?["unchanged"] == .bool(true))
    #expect(repeated["changes"]?["changed"] == .array([]))
    // Changing the address is a new scope even with the same owner versions.
    let other = try await host.context(.init(method: "observe", arguments: .object([
      "target": try .encode(CollaborationTarget(kind: .page, id: owner.pageID)), "elementID": .string("element-39"),
      "since": try #require(first["changeKeys"])])))
    #expect(other["content"]?["element"]?["id"] == .string("element-39"))
  }

  @Test func previewOnlyDecodesItsBoundedMembers() async throws {
    let owner = try Owner(), host = owner.host()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    try owner.poison("element-39")
    let value = try await host.context(.init(method: "observe"))
    #expect(value["content"]?["elements"]?.array.count == 32)
    #expect(value["content"]?["truncated"] == .bool(true))
  }
}
