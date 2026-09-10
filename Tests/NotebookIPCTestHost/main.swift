import Foundation
import Darwin
import NotebookCore

// The isolated harness owns this process through stdin. Its fixture controls are
// not part of NotebookCommand and cannot be sent to the production Unix socket.
struct FixtureControl: Decodable, Sendable {
  let id: UUID
  let operation: String
  let value: JSONValue?
}
struct Seed: Decodable {
  let actor: UUID
  let itemID: UUID
  let pageID: UUID
  let rootBoardID: UUID
  let title: String
  let pageSize: PageSize
  let presence: SessionPresence
}
actor TestOwner {
  let store: NotebookStore
  init(root: URL) { store = NotebookStore(root: root) }
  func handle(_ command: NotebookCommand) throws -> JSONValue { try NotebookCommandDispatcher(store: store).handle(command) }
  func control(_ command: FixtureControl) throws -> JSONValue {
    let value = command.value ?? .null
    switch command.operation {
    case "seed":
      let fixture = try value.decode(Seed.self)
      // The fixture submits creation intent, never a handwritten archive or a
      // bounded MCP projection. Core authors the same order witnesses and
      // causal fields as native notebook creation before the atomic publish.
      let stamp = VersionStamp(counter: 0, actor: fixture.actor)
      let page = PageDocument(id: fixture.pageID, size: fixture.pageSize, actor: fixture.actor)
      let workspace = WorkspaceIndex(
        items: [.notebook(id: fixture.itemID, title: fixture.title, pageIDs: [page.id])],
        selectedItemID: fixture.itemID, selectedPageID: page.id, stamp: stamp, rootBoardID: fixture.rootBoardID)
      let board = BoardHierarchy.initial(rootBoardID: fixture.rootBoardID, itemIDs: [fixture.itemID], actor: fixture.actor)
      try store.saveWorkspaceBundle(index: workspace, page: page, board: board)
      try store.saveSpatialInk(SpatialInkJournal(stamp: stamp))
      try store.savePresence(fixture.presence)
      return .object(["workspaceStamp": try .encode(store.workspaceHeader().stamp),
        "page": try .encode(store.loadPage(page.id)), "spatialInkStamp": try .encode(store.loadSpatialInk().stamp),
        "presence": try .encode(store.loadPresence())])
    case "appendPages":
      let count = try value.decode(Int.self)
      guard (1...128).contains(count) else { throw NotebookStorageError.limitExceeded("fixture_pages") }
      let presence = try store.loadPresence()
      guard let id = presence.selectedItemID, let item = try store.readItemHeader(id) else { throw CocoaError(.fileNoSuchFile) }
      var projection = try store.workspaceProjection(items: [item.item], selectedItemID: id, selectedPageID: item.firstPageID)
      var pages: [UUID] = []
      for _ in 0..<count {
        guard let append = projection.appendPage(in: id, actor: projection.stamp.actor, pageSize: .init(width: 834, height: 1194)) else {
          throw NotebookStorageError.invalidTransaction("fixture append")
        }
        _ = try store.saveWorkspaceSelection(index: projection, createdPage: append.createdPage)
        pages.append(append.pageID)
        try projection.retainPageProjection([append.pageID])
      }
      return try .encode(pages)
    case "page": try store.savePage(value.decode(PageDocument.self))
    case "presence": try store.savePresence(value.decode(SessionPresence.self))
    case "ink": try store.saveSpatialInk(value.decode(SpatialInkJournal.self))
    case "input": try store.saveInputActivity(value.decode(NotebookInputActivity.self))
    case "targetReceipt": try store.saveTargetRender(value.decode(TargetRenderReceipt.self))
    case "renderRequests": return try .encode(store.targetRenderRequests())
    case "readFixture":
      // Explicit whole-fixture inspection only in the test process, not an MCP command.
      let workspace = try store.loadIndex()
      return .object(["workspace": try .encode(workspace), "board": try .encode(store.loadBoard(items: workspace.items)),
        "spatialInk": try .encode(store.loadSpatialInk()), "presence": try .encode(store.loadPresence())])
    default: throw CollaborationError("invalid_fixture_control", "Неизвестное действие изолированной фикстуры.")
    }
    return .bool(true)
  }
}

final class TestOutput: @unchecked Sendable {
  let lock = NSLock()
  func write(_ value: JSONValue) {
    lock.withLock {
      let bytes = (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
      FileHandle.standardOutput.write(bytes + Data([10]))
    }
  }
}

guard CommandLine.arguments.count == 3 else { fatalError("Usage: notebook-ipc-test-host TEMP_ROOT PRIVATE_SOCKET") }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let socket = URL(fileURLWithPath: CommandLine.arguments[2])
let owner = TestOwner(root: root), output = TestOutput()
let server = NotebookIPCServer(socketURL: socket) { try await owner.handle($0) }
try server.start()
output.write(.object(["ready": .bool(true)]))
var pending = Data()
while true {
  var buffer = [UInt8](repeating: 0, count: 65_536)
  let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
  if count < 0 && errno == EINTR { continue }
  if count <= 0 { break }
  pending.append(contentsOf: buffer.prefix(count))
  guard pending.count <= NotebookIPC.maximumFrameBytes else { break }
  while let end = pending.firstIndex(of: 10) {
    let bytes = pending.prefix(upTo: end); pending.removeSubrange(...end)
    let control = try JSONDecoder().decode(FixtureControl.self, from: bytes)
    Task.detached {
      do { output.write(.object(["id": .string(control.id.uuidString.lowercased()), "result": try await owner.control(control)])) }
      catch {
        let detail = (error as? CollaborationError) ?? CollaborationError("fixture_rejected", error.localizedDescription)
        output.write(.object(["id": .string(control.id.uuidString.lowercased()), "error": .object(["code": .string(detail.code), "message": .string(detail.message)])]))
      }
    }
  }
}
await server.stopAndDrain()
