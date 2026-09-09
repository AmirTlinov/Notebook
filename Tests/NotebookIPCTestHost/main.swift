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
  let workspace: WorkspaceIndex
  let page: PageDocument
  let board: BoardHierarchy
  let spatialInk: SpatialInkJournal
  let presence: SessionPresence
}
struct WorkspaceBundle: Decodable {
  let workspace: WorkspaceIndex
  let page: PageDocument
  let board: BoardHierarchy
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
      try store.saveWorkspaceBundle(index: fixture.workspace, page: fixture.page, board: fixture.board)
      try store.saveSpatialInk(fixture.spatialInk)
      try store.savePresence(fixture.presence)
    case "page": try store.savePage(value.decode(PageDocument.self))
    case "presence": try store.savePresence(value.decode(SessionPresence.self))
    case "ink": try store.saveSpatialInk(value.decode(SpatialInkJournal.self))
    case "workspaceBundle":
      let fixture = try value.decode(WorkspaceBundle.self)
      try store.saveWorkspaceBundle(index: fixture.workspace, page: fixture.page, board: fixture.board)
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
