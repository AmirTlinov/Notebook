import Foundation
import Testing
import NotebookScriptProtocol
import NotebookScriptWorker

struct NotebookMarkupExportTests {
  @Test func realQuickJSParserPreservesEmbeddedImageAndLinkCapabilities() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bootstrap = try String(contentsOf: root.appendingPathComponent("Sources/NotebookMarkupService/Resources/notebook-markup.js"), encoding: .utf8)
    let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="60"><text x="4" y="30">Actual image</text></svg>"#
    let html = "<h2 id='top'>Title</h2><img src='data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())'><p><a href='#top'>Back</a> \\(x=1\\)</p>"
    let arguments = try JSONSerialization.data(withJSONObject: ["kind": "documentTeX", "document": ["preamble": "", "paperSize": "a4", "blocks": [["kind": "markdown", "id": "body", "source": html]]]])
    let engine = NotebookQuickJSEngine(bootstrap: bootstrap, maximumArguments: 32*1024*1024, maximumResultBytes: 32*1024*1024) { _, _, done in
      done(.init(code: "unexpected_host_call"))
    }
    let result: NotebookWorkerReply = await withCheckedContinuation { continuation in
      engine.start(code: "return globalThis.notebookMarkup(args);", arguments: arguments) { continuation.resume(returning: $0) }
    }
    #expect(result.code == nil, "\(result.message ?? "")")
    let bytes = try #require(result.value)
    let decoded = try JSONSerialization.jsonObject(with: bytes)
    let value = try #require(decoded as? [String: Any])
    let assets = try #require(value["assets"] as? [[String: Any]])
    #expect(assets.count == 1 && assets[0]["mediaType"] as? String == "image/svg+xml")
    #expect(assets[0]["data"] as? String == Data(svg.utf8).base64EncodedString())
    let source = try #require(value["source"] as? String)
    #expect(source.contains("\\NotebookPrintImage[scale=0.75,keepaspectratio]{notebook-image-0.pdf}"))
    #expect(source.contains("\\hyperlink{nb-74-6f-70}{Back}") && source.contains("\\(x=1\\)"))
  }
}
