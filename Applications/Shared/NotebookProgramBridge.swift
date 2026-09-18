import Foundation
import NotebookCore
import WebKit

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
