import Foundation
import Testing
@testable import NotebookCore
@testable import NotebookScriptHost

@MainActor @Suite("SDK v2 snapshots", .serialized)
struct NotebookSDKV2ReadTests {
  @MainActor final class Owner {
    let store: NotebookStore
    init() throws {
      store = .init(root: FileManager.default.temporaryDirectory.appendingPathComponent("sdk-v2-host-\(UUID())"))
      _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    }
    func read(_ query: NotebookCommand) throws -> JSONValue { try NotebookCommandDispatcher(store: store).handle(query) }
    func persist(_ op: @Sendable (NotebookStore) throws -> JSONValue) throws -> JSONValue { try op(store) }
  }
  @Test func oneReadReturnsDataBasisAndCoverageWithoutValuesEnvelope() async throws {
    let owner = try Owner()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let host = NotebookScriptCoordinator(command: { try await owner.read($0) }, persistence: { try await owner.persist($0) },
      workingDirectory: owner.store.root.appendingPathComponent("derived/script-runtime"))
    let value = try await host.context(.init(method: "read", arguments: .object(["kind": .string("workspaceHeader")])))
    #expect(value["data"]?["workspaceID"] != nil)
    #expect(value["basis"]?["owners"] != nil)
    #expect(value["coverage"]?["complete"] == .bool(true))
    #expect(value["values"] == nil)
  }
}
