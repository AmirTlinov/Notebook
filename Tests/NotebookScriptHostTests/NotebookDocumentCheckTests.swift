import Foundation
import Testing
@testable import NotebookCore
@testable import NotebookScriptHost

/// Tests the SDK adapter, not WebKit execution: the canonical renderer's
/// accepted evidence is supplied explicitly and must never be strengthened.
@MainActor @Suite("Exact document check adapter", .serialized)
struct NotebookDocumentCheckTests {
  @MainActor private final class Owner {
    let store: NotebookStore
    let documentID = UUID(), renderID = UUID()
    var requests: [NotebookCommand] = []
    var programs: [DocumentProgramCheck] = []
    var buildID: String? = "build-one"
    var pending = false, sourceChanged = false
    init() throws {
      store = .init(root: FileManager.default.temporaryDirectory.appendingPathComponent("document-check-\(UUID())"))
      _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    }
    deinit { try? FileManager.default.removeItem(at: store.root) }
    func host() -> NotebookScriptCoordinator {
      NotebookScriptCoordinator(command: { try await self.command($0) }, persistence: { try await self.persist($0) },
        workingDirectory: store.root.appendingPathComponent("derived/script-runtime"))
    }
    func persist(_ operation: @Sendable (NotebookStore) throws -> JSONValue) throws -> JSONValue { try operation(store) }
    func command(_ command: NotebookCommand) throws -> JSONValue {
      requests.append(command)
      switch command.command {
      case .render:
        return .object(["id": .string(renderID.uuidString), "sourceRevision": .string("reference-cut")])
      case .read:
        #expect(command.queries?.count == 1 && command.queries?.first?.kind == .targetRenderReceipt)
        #expect(command.queries?.first?.id == renderID)
        if pending { return .object(["values": .array([.null])]) }
        var receipt: [String: JSONValue] = ["status": .string("ready"), "pngSHA256": .string(String(repeating: "a", count: 64)),
          "programs": try .encode(programs), "diagnostics": .array([])]
        receipt["buildID"] = buildID.map(JSONValue.string)
        return .object(["values": .array([.object(receipt)])])
      case .reference: return .object(["revision": .string(sourceChanged ? "later-cut" : "reference-cut")])
      default: throw CollaborationError("unexpected_command", "Document check must reuse the existing renderer.")
      }
    }
    var check: JSONValue { .object(["id": .string(documentID.uuidString), "expectedRevision": .string("owner-basis"), "pageIndex": .number(2)]) }
    func render(build: String) -> JSONValue { .object(["target": .object(["kind": .string("document"), "id": .string(documentID.uuidString)]),
      "expectedRevision": .string("owner-basis"), "pageIndex": .number(2), "expectedBuildID": .string(build)]) }
  }

  @Test func selectedStartupFailureKeepsTheExactReadableArtifactAndOtherInstancesUnchecked() async throws {
    let owner = try Owner(), host = owner.host()
    owner.programs = [.init(instanceID: "selected", sourceBasis: "program-cut", status: .ready),
      .init(instanceID: "broken", status: .failed), .init(instanceID: "off-page", sourceBasis: "other-cut", status: .notChecked)]
    let value = try await host.context(.init(method: "documentCheck", arguments: owner.check))
    #expect(value["data"]?["status"] == .string("failed"))
    #expect(value["data"]?["code"] == .string("document_diagnostics"))
    #expect(value["data"]?["buildID"] == .string("build-one"))
    #expect(value["data"]?["artifact"]?["id"] == .string(owner.renderID.uuidString))
    let evidence = try JSONValue.encode(owner.programs)
    #expect(value["data"]?["programs"] == evidence)
    #expect(owner.requests.first?.command == .render && owner.requests.first?.pageIndex == 2)
    #expect(owner.requests.first?.expectedRevision == "owner-basis")
  }

  @Test func pendingOrUnidentifiedBuildNeverBecomesASuccessfulCheck() async throws {
    let owner = try Owner(), host = owner.host(); owner.pending = true
    let pending = try await host.context(.init(method: "documentCheck", arguments: owner.check))
    #expect(pending["data"]?["status"] == .string("pending"))
    #expect(pending["data"]?["programs"] == .array([]) && pending["data"]?["artifact"] == nil)
    owner.pending = false; owner.buildID = nil
    let unverified = try await host.context(.init(method: "documentCheck", arguments: owner.check))
    #expect(unverified["data"]?["status"] == .string("unverified"))
    #expect(unverified["data"]?["code"] == .string("build_identity_unavailable"))
  }

  @Test func repeatedPreviewRequiresBothTheCheckedBuildAndCurrentSource() async throws {
    let owner = try Owner(), host = owner.host()
    do {
      _ = try await host.context(.init(method: "render", arguments: owner.render(build: "older-build")))
      Issue.record("An older checked build must not select a different picture")
    } catch let error as CollaborationError { #expect(error.code == "build_changed") }
    let same = try await host.context(.init(method: "render", arguments: owner.render(build: "build-one")))
    #expect(same["data"]?["artifact"] != nil)
    owner.sourceChanged = true
    do {
      _ = try await host.context(.init(method: "render", arguments: owner.render(build: "build-one")))
      Issue.record("A stale source must not produce a current artifact")
    } catch let error as CollaborationError { #expect(error.code == "revision_conflict") }
  }
}
