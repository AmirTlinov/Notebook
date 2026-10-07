import Foundation
import Testing
import NotebookCore
@testable import NotebookScriptHost

struct NotebookScriptHelpTests {
  @Test @MainActor func repeatedCoordinatorHelpPreservesTheBundledResponseAndMeasuresDecodeCost() async throws {
    let url = try #require(Bundle.module.url(forResource: "sdk-reference", withExtension: "json"))
    let clock = ContinuousClock()
    var decoded: JSONValue = .null, decodeMS: [Double] = [], sourceBytes = 0
    for _ in 0..<3 {
      let start = clock.now
      let data = try Data(contentsOf: url)
      decoded = try JSONDecoder().decode(JSONValue.self, from: data)
      decodeMS.append(Self.milliseconds(start.duration(to: clock.now)))
      sourceBytes = data.count
    }
    let expected = JSONValue.object(["api_version": .number(2), "topic": .string("operations"),
      "contract": try #require(decoded["operations"])])
    let coordinator = NotebookScriptCoordinator(command: { _ in
      throw CollaborationError("unexpected_help_command", "Help must not start a domain command.")
    }, reader: { _ in
      throw CollaborationError("unexpected_help_reader", "Help must not open a workspace reader.")
    }, persistence: { _ in
      throw CollaborationError("unexpected_help_persistence", "Help must not open or read a workspace.")
    }, workingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("sdk-help-\(UUID())"))
    var retrievalMS: [Double] = []
    for _ in 0..<5 {
      let start = clock.now
      let reply = try await coordinator.context(.init(method: "help", arguments: .object(["topic": .string("operations")])))
      retrievalMS.append(Self.milliseconds(start.duration(to: clock.now)))
      #expect(reply == expected)
    }
    do {
      _ = try await coordinator.context(.init(method: "help", arguments: .object(["topic": .string("operation/missing")])))
      Issue.record("An unknown topic must retain its error after successful help reads")
    } catch let error as CollaborationError { #expect(error.code == "unknown_help_topic") }
    let measurement: [String: Any] = ["fixture": "bundled_reference_real_coordinator", "sourceBytes": sourceBytes,
      "fullReadDecodeMS": decodeMS, "helpRetrievalMS": retrievalMS,
      "replyBytes": try JSONEncoder().encode(expected).count, "referencePayloadBytes": decoded.retainedPayloadBytes]
    let data = try JSONSerialization.data(withJSONObject: measurement, options: [.sortedKeys])
    print("SDK_HELP_MEASUREMENTS \(String(decoding: data, as: UTF8.self))")
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
  }

  @Test func compactIndexResolvesEveryIndividualOperationFromTheBundledReference() throws {
    let index = try NotebookScriptAPI.documentation("operations")
    let operations = try #require(index["contract"]?["items"])
    guard case .array(let items) = operations else { Issue.record("Operation index must be an array"); return }
    #expect(items.count == 20)
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
    let files = try #require(interactive["contract"]?["files"]).arrayValues
    #expect(Set(files.compactMap { $0.string("path") }) == ["programs/counter/index.html", "programs/counter/style.css", "programs/counter/main.js"])
    let script = try #require(files.first { $0.string("path") == "programs/counter/main.js" })
    let source = try #require(script.string("source"))
    #expect(source.contains("notebook.ready(Promise.resolve().then(draw))"))
    #expect(source.contains("notebook.commit") && source.contains("notebookstate"))
    let example = try #require(interactive["contract"]?.string("example"))
    #expect(example.contains("putDocumentFile") && example.contains("patchDocumentFile"))
    #expect(example.contains("\\NotebookInteractive") && example.contains("{programs/counter}"))
    let transaction = try NotebookScriptAPI.documentation("transaction")
    // Match the canonical complete-action budget and JSON representation.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    #expect(try encoder.encode(transaction["contract"]?["input"]).count < 28 * 1024)
  }
}
