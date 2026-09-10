import Foundation
import NotebookCore
import Testing
@testable import NotebookArchiveTransfer

@Suite("Only the offline converter owns retired document and board meanings")
struct LegacyDocumentAndBoardTests {
  private func object(_ value: some Encodable) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
  }
  private func data(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
  private func oldBoard(_ current: BoardDocument) throws -> [String: Any] {
    var value = try object(current)
    let free = try #require(value.removeValue(forKey: "freeItems") as? [[String: Any]])
    value["freeNotebooks"] = free.map { original in
      var item = original; item["notebookID"] = item.removeValue(forKey: "itemID"); return item
    }
    let stacks = try #require(value["stacks"] as? [[String: Any]])
    value["stacks"] = stacks.map { original in
      var stack = original; stack["notebookIDs"] = stack.removeValue(forKey: "itemIDs"); return stack
    }
    value["format"] = 1
    return value
  }

  @Test func documentOneAssignsA4ButPreservesUUIDBlocksAndCausalHistory() throws {
    var document = DocumentDocument(actor: UUID(), paperSize: .a4, preamble: "\\newcommand{\\x}{x}", blocks: [
      .markdown(id: "body", source: "# Source"),
      .interactive(id: "program", html: "<button>+</button>", initialState: .object(["paperSize": .string("not metadata"), "format": .number(1)]))])
    let changed = document.replaceBlockSource(id: "body", source: "# Human continuation", actor: UUID())
    #expect(changed)
    var old = try object(document); old["format"] = 1; old.removeValue(forKey: "paperSize")
    let bytes = try data(old)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(DocumentDocument.self, from: bytes) }
    #expect(try convertLegacyDocument(bytes) == document)
    #expect(try convertLegacyDocument(JSONEncoder().encode(document)) == document)
    old["format"] = 77
    #expect(throws: DecodingError.self) { try convertLegacyDocument(data(old)) }
  }

  @Test func oldPlacementsAndStacksRetainUUIDCoordinatesOrderAndClocks() throws {
    let actor = UUID(), ids = [UUID(), UUID(), UUID()]
    var board = BoardDocument.initial(itemIDs: ids, actor: actor)
    let stacked = board.createStack(moving: ids[0], onto: ids[1], actor: actor)
    #expect(stacked != nil)
    let bytes = try data(oldBoard(board))
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(BoardDocument.self, from: bytes) }
    #expect(try convertLegacyBoard(bytes) == board)
    #expect(try convertLegacyBoard(JSONEncoder().encode(board)) == board)
    let node = BoardNode(id: UUID(), board: board)
    let tree = BoardHierarchy(rootBoardID: node.id, boards: [node], stamp: board.stamp)
    var old = try object(tree), oldNode = try object(node)
    oldNode["board"] = try oldBoard(board)
    oldNode.removeValue(forKey: "portalCamera"); oldNode.removeValue(forKey: "portalStamp")
    old["boards"] = [oldNode]
    #expect(try convertLegacyHierarchy(data(old)) == tree)
    oldNode["portalCamera"] = ["invalid": true]; old["boards"] = [oldNode]
    #expect(throws: DecodingError.self) { try convertLegacyHierarchy(data(old)) }
  }

  @Test func completeArchiveUsesExternalConversionsBeforeCheckpointPublication() throws {
    let root = try transferTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try LegacyArchiveFixture.make(at: root.appendingPathComponent("backup"))
    let workspaceURL = fixture.root.appendingPathComponent("workspace.json")
    var workspace = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: workspaceURL)) as? [String: Any])
    var items = try #require(workspace["items"] as? [[String: Any]])
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "source", source: "Не менять исходник")])
    items.append(["id": document.id.uuidString, "kind": "document", "title": "Old document", "pageIDs": []])
    workspace["items"] = items
    try data(workspace).write(to: workspaceURL)
    let state = DocumentStateJournal(id: document.id, actor: document.contentStamp.actor)
    var legacyDocument = try object(document); legacyDocument["format"] = 1; legacyDocument.removeValue(forKey: "paperSize")
    try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("documents"), withIntermediateDirectories: true)
    try data(legacyDocument).write(to: fixture.root.appendingPathComponent("documents/" + document.id.uuidString.lowercased() + ".json"))
    try writeTransferFixture(state, to: fixture.root.appendingPathComponent("document-states/" + document.id.uuidString.lowercased() + ".json"))
    let rootID = try #require((workspace["rootBoardID"] as? String).flatMap(UUID.init(uuidString:)))
    let itemIDs = try items.map { try #require(($0["id"] as? String).flatMap(UUID.init(uuidString:))) }
    let board = BoardDocument.initial(itemIDs: itemIDs, actor: document.contentStamp.actor)
    let hierarchy = BoardHierarchy(rootBoardID: rootID, boards: [BoardNode(id: rootID, board: board)], stamp: board.stamp)
    var tree = try object(hierarchy), node = try object(hierarchy.boards[0]); node["board"] = try oldBoard(board)
    node.removeValue(forKey: "portalCamera"); node.removeValue(forKey: "portalStamp"); tree["boards"] = [node]
    try data(tree).write(to: fixture.root.appendingPathComponent("board.json"))
    let before = try inventory(fixture.root), destination = root.appendingPathComponent("prepared")
    let report = try ArchiveTransfer.prepare(source: fixture.root, destination: destination, workspaceID: UUID())
    #expect(report.convertedOwners.map(\.path) == ["board.json", "documents/" + document.id.uuidString.lowercased() + ".json"])
    for conversion in report.convertedOwners {
      #expect(conversion.sourceSHA256 == before.first { $0.path == conversion.path }?.sha256)
      #expect(conversion.sourceSHA256 != conversion.preparedOwnerSHA256)
    }
    let store = NotebookStore(root: destination.appendingPathComponent("archive"))
    #expect(try store.loadDocument(document.id) == document.materializingCausalVersions())
    #expect(try store.loadDocumentState(document.id) == state)
    #expect(try store.loadBoard(items: store.loadIndex().items) == hierarchy)
    #expect(try inventory(fixture.root) == before)
  }
}
