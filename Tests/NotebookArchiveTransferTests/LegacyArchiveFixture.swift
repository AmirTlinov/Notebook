import Foundation
import NotebookCore
import Testing

struct LegacyArchiveFixture {
  let root: URL
  let page: PageDocument
  let context: SharedContext
  static func make(at root: URL) throws -> Self {
    let actor = UUID()
    let initial = WorkspaceIndex.initial(actor: actor, pageSize: .init(width: 834, height: 1194))
    var catalog = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(initial.index)) as? [String: Any])
    catalog["format"] = 3
    catalog["selectedItemID"] = initial.index.selectedItemID.uuidString
    catalog["selectedPageID"] = initial.page.id.uuidString
    for key in ["collaboration", "pageOrders", "pageOrderNodes", "isProjection"] { catalog.removeValue(forKey: key) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: catalog).write(to: root.appendingPathComponent("workspace.json"))
    try writeTransferFixture(BoardHierarchy.initial(rootBoardID: initial.index.rootBoardID, itemIDs: initial.index.items.map(\.id), actor: actor), to: root.appendingPathComponent("board.json"))
    try writeTransferFixture(SpatialInkJournal(stamp: .init(counter: 0, actor: actor)), to: root.appendingPathComponent("spatial-ink.json"))
    let presence = SessionPresence(mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194))
    var oldPresence = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(presence)) as? [String: Any])
    oldPresence["format"] = 4
    try JSONSerialization.data(withJSONObject: oldPresence).write(to: root.appendingPathComponent("last-context.json"))
    try writeTransferFixture(initial.page, to: root.appendingPathComponent("pages/\(initial.page.id.uuidString.lowercased()).json"))
    let context = SharedContext(entries: [.init(author: .human, references: [], text: "Сохрани вопрос", stamp: .init(counter: 1, actor: actor))])
    try writeTransferFixture(context, to: root.appendingPathComponent("collaboration/contexts/\(context.id.uuidString.lowercased()).json"))
    try writeTransferFixture(SharedContextSelection(contextID: context.id, stamp: .init(counter: 2, actor: actor)), to: root.appendingPathComponent("collaboration/selection.json"))
    try writeTransferFixture(["format": 2], to: root.appendingPathComponent("collaboration/format.json"))
    return .init(root: root, page: initial.page, context: context)
  }
}

func transferTestRoot() throws -> URL {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-test-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

func writeTransferFixture(_ value: some Encodable, to url: URL) throws {
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try JSONEncoder().encode(value).write(to: url)
}
