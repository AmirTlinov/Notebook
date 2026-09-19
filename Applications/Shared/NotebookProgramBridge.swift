import Foundation
import NotebookCore
import WebKit

/// A writer refusal for an obsolete causal basis is not an I/O failure. The
/// old heap has no remaining publication rights and need not pin a closing UI.
enum NotebookProgramCheckpointError: Error { case superseded }

/// One source for the public browser API; transport remains with each surface.
enum NotebookProgramBridge {
  static let script: String = {
    guard let url = Bundle.main.url(forResource: "notebook-program", withExtension: "js", subdirectory: "WebResources")
      ?? Bundle.main.url(forResource: "notebook-program", withExtension: "js"),
      let source = try? String(contentsOf: url, encoding: .utf8) else {
      // Missing resources must fail preparation, never install a different API.
      return "throw new Error('notebook_program_bridge_missing');"
    }
    return source
  }()

  static let documentScript: String = {
    guard let url = Bundle.main.url(forResource: "document-program", withExtension: "js", subdirectory: "WebResources")
      ?? Bundle.main.url(forResource: "document-program", withExtension: "js"),
      let source = try? String(contentsOf: url, encoding: .utf8) else {
      return "throw new Error('notebook_document_program_bridge_missing');"
    }
    return source
  }()

  @MainActor static func document(block: DocumentBlock, state: JSONValue, token: String,
    package: NotebookProgramPackage, origin: URL) throws -> NotebookProgramAssets.Document {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let configuration: JSONValue = .object(["blockID": .string(block.id), "token": .string(token), "state": state, "requiresReady": .bool(true)])
    let json = String(decoding: try encoder.encode(configuration), as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
    return .init(before: """
      <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
      <meta http-equiv="Content-Security-Policy" content="\(NotebookProgramAssets.policy(origin: origin))">
      <style>html,body{margin:0;min-height:100%;background:transparent;color:#171713;font-family:-apple-system,BlinkMacSystemFont,sans-serif}*{box-sizing:border-box}</style>
      \(NotebookProgramAssets.style(package, origin: origin))
      <script>\(script)
      \(documentScript)
      installNotebookDocumentProgram(\(json),createNotebookProgram);</script>
      </head><body>
      """, after: "\(NotebookProgramAssets.script(package, origin: origin))</body></html>")
  }

  /// A parked WebKit can throttle its timers as well as rAF. The native owner
  /// bounds the lifecycle request independently and ignores a late completion.
  @MainActor
  static func lifecycle(_ operation: String, controller: String, in web: WKWebView) async throws -> JSONValue {
    try await withCheckedThrowingContinuation { continuation in
      var completed = false
      let deadline = Task { @MainActor in
        do { try await Task.sleep(for: .milliseconds(4500)) } catch { return }
        guard !completed else { return }; completed = true
        continuation.resume(throwing: SceneRenderError.snapshotPending("program_\(operation)_timeout"))
      }
      web.callAsyncJavaScript("return await window[controller][operation]();",
        arguments: ["controller": controller, "operation": operation], in: nil, in: .page) { result in
        guard !completed else { return }; completed = true; deadline.cancel()
        switch result {
        case .success(let value):
          do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            continuation.resume(returning: try JSONDecoder().decode(JSONValue.self, from: data))
          } catch { continuation.resume(throwing: error) }
        case .failure(let error): continuation.resume(throwing: error)
        }
      }
    }
  }
}
