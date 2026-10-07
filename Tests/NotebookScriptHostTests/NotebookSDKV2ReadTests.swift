import Foundation
import Testing
@testable import NotebookCore
@testable import NotebookScriptHost

@MainActor @Suite("SDK v2 snapshots", .serialized)
struct NotebookSDKV2ReadTests {
  @MainActor final class Owner {
    let store: NotebookStore
    private lazy var querySession = NotebookReadSession(store: store)
    init() throws {
      store = .init(root: FileManager.default.temporaryDirectory.appendingPathComponent("sdk-v2-host-\(UUID())"))
      _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    }
    func read(_ query: NotebookCommand) throws -> JSONValue {
      let command = try NotebookReadCommand(query)
      return try querySession.observe { try $0.handle(command) }
    }
    func observe(_ operation: @Sendable (NotebookQueryCut) throws -> JSONValue) throws -> JSONValue {
      try querySession.observe(operation)
    }
    func persist(_ op: @Sendable (NotebookStore) throws -> JSONValue) throws -> JSONValue { try op(store) }
  }
  @Test func oneReadReturnsDataBasisAndCoverageWithoutValuesEnvelope() async throws {
    let owner = try Owner()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let host = NotebookScriptCoordinator(command: { try await owner.read($0) }, reader: { try await owner.observe($0) }, persistence: { try await owner.persist($0) },
      workingDirectory: owner.store.root.appendingPathComponent("derived/script-runtime"))
    let value = try await host.context(.init(method: "read", arguments: .object(["kind": .string("workspaceHeader")])))
    #expect(value["data"]?["workspaceID"] != nil)
    #expect(value["basis"]?["owners"] != nil)
    #expect(value["coverage"]?["complete"] == .bool(true))
    #expect(value["values"] == nil)
  }

  @Test func storageDiagnosticUsesTheObservationCutWithoutAdvancingContent() async throws {
    let owner = try Owner()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let cursor = try owner.store.currentReadCursor(), sequence = try owner.store.currentChangeCursor()
    let host = NotebookScriptCoordinator(command: { try await owner.read($0) }, reader: { try await owner.observe($0) }, persistence: { try await owner.persist($0) },
      workingDirectory: owner.store.root.appendingPathComponent("derived/script-runtime"))
    let value = try await host.context(.init(method: "read", arguments: .object(["kind": .string("storageUsage")])))
    let usage = try #require(value["data"]).decode(NotebookStorageUsage.self)
    #expect(usage.cut.readRevision == cursor && usage.cut.changeSequence == sequence)
    #expect(value["cursor"] == .string(String(cursor)))
    #expect(value["basis"]?["workspaceID"] == (try .encode(usage.cut.workspaceID)))
    #expect(value["basis"]?["owners"] == .array([]))
    #expect(usage.logicalStatus == .snapshot && usage.reachability == .partial)
    #expect(try owner.store.currentReadCursor() == cursor)
    #expect(try owner.store.currentChangeCursor() == sequence)
  }
}
