import Foundation
import Testing
import NotebookCore
@testable import NotebookScriptHost

struct NotebookScriptHelpTests {
  @Test func compactIndexResolvesEveryIndividualOperationFromTheBundledReference() throws {
    let index = try NotebookScriptAPI.documentation("operations")
    let operations = try #require(index["contract"]?["items"])
    guard case .array(let items) = operations else { Issue.record("Operation index must be an array"); return }
    #expect(items.count == 22)
    #expect(try JSONEncoder().encode(index).count < 6 * 1024)
    for item in items {
      let name = try #require(item.string("name")), topic = try #require(item.string("topic"))
      #expect(topic == "operation/" + name)
      let detail = try NotebookScriptAPI.documentation(topic)
      #expect(detail["contract"]?["name"] == .string(name))
      #expect(detail["contract"]?["input"]?["properties"]?["kind"]?["const"] == .string(name))
      #expect(try JSONEncoder().encode(detail).count < 12 * 1024)
    }
    #expect(throws: CollaborationError.self) { try NotebookScriptAPI.documentation("operation/missing") }
    #expect(throws: CollaborationError.self) { try NotebookScriptAPI.documentation("operation/createDocument/extra") }
    #expect(throws: CollaborationError.self) { try NotebookScriptAPI.documentation("operationDetails") }
  }

  @Test func initialHelpExposesCompletionAndEmbeddedReadinessBeforeAnyRender() throws {
    let index = try NotebookScriptAPI.documentation(nil)
    let effects = String(decoding: try JSONEncoder().encode(index["effects"]), as: UTF8.self)
    #expect(effects.contains("mp4") && effects.contains("moment?:saved|presented"))
    let completion = try #require(index.string("run_completion"))
    #expect(completion.contains("queued/running OR has_more=true"))
    #expect(completion.contains("completed/failed/cancelled/interrupted AND has_more=false"))
    let interactive = try NotebookScriptAPI.documentation("interactive")
    let source = try #require(interactive["contract"]?["block"]?.string("javaScript"))
    #expect(source.contains("notebook.ready(Promise.resolve().then(draw))"))
    let transaction = try NotebookScriptAPI.documentation("transaction")
    // Same compact-action budget as MCP's public schema contract, including
    // the newly supported connector routing and Foundation's slash escaping.
    #expect(try JSONEncoder().encode(transaction["contract"]?["input"]).count < 26 * 1024)
  }
}
