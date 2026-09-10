import AppKit
import Foundation
import WebKit

/// A dependency acceptance executable, not an application model or archive owner.
/// The installed Notebook and Lab are never opened by this process.
@MainActor
private final class DependencyProbe: NSObject, WKURLSchemeHandler, WKScriptMessageHandler, WKNavigationDelegate {
  private let files: [String: URL]
  private let output: URL
  private var webView: WKWebView!
  private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var watchdog: Task<Void, Never>?
  private let scenarios = ["science", "output", "failure", "infinite", "isolation"]
  private var scenarioIndex = -1
  private var runID = ""
  private var executionStart = ContinuousClock.now
  private var bootStart = ContinuousClock.now
  private var bootMilliseconds: [Double] = []
  private var results: [[String: Any]] = []
  private var deniedPaths: [String] = []
  private var served: Set<String> = []
  private var checks = 0

  init(resources: URL, harness: URL, output: URL) throws {
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("manifest.json"))) as! [String: Any]
    var files: [String: URL] = [:]
    for entry in manifest["files"] as! [[String: Any]] {
      let path = entry["path"] as! String
      if !path.contains("/") { files["/" + path] = resources.appendingPathComponent(path) }
    }
    files["/index.html"] = harness.appendingPathComponent("index.html")
    files["/worker.mjs"] = harness.appendingPathComponent("worker.mjs")
    self.files = files
    self.output = output
    super.init()
  }

  func start() {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.inactiveSchedulingPolicy = .none
    configuration.setURLSchemeHandler(self, forURLScheme: "notebook-computation")
    configuration.userContentController.add(self, name: "probe")
    webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
    webView.navigationDelegate = self
    webView.load(URLRequest(url: URL(string: "notebook-computation://bundle/index.html")!))
    armWatchdog(seconds: 30)
  }

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    let key = ObjectIdentifier(task)
    guard let url = task.request.url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.scheme == "notebook-computation", components.host == "bundle",
          components.user == nil, components.password == nil, components.port == nil,
          components.query == nil, components.fragment == nil,
          task.request.httpMethod == "GET",
          let file = files[components.percentEncodedPath] else {
      deniedPaths.append(task.request.url?.absoluteString ?? "missing URL")
      task.didFailWithError(URLError(.noPermissionsToReadFile))
      return
    }
    let mime: String
    switch file.pathExtension {
    case "html": mime = "text/html; charset=utf-8"
    case "mjs": mime = "application/javascript"
    case "wasm": mime = "application/wasm"
    case "json": mime = "application/json"
    default: mime = "application/octet-stream"
    }
    requests[key] = Task { [weak self] in
      do {
        let bytes = try await Task.detached(priority: .utility) { try Data(contentsOf: file) }.value
        guard !Task.isCancelled, let self, self.requests.removeValue(forKey: key) != nil else { return }
        self.served.insert(file.lastPathComponent)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
          "Content-Type": mime, "Content-Length": String(bytes.count),
          "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store",
        ])!
        task.didReceive(response)
        task.didReceive(bytes)
        task.didFinish()
      } catch {
        guard !Task.isCancelled, self?.requests.removeValue(forKey: key) != nil else { return }
        task.didFailWithError(error)
      }
    }
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
    requests.removeValue(forKey: ObjectIdentifier(task))?.cancel()
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
    action.request.url?.absoluteString == "notebook-computation://bundle/index.html" ? .allow : .cancel
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail("WebKit process terminated") }

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame,
          let text = message.body as? String, text.utf8.count <= 32768,
          let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
          let kind = value["kind"] as? String else { fail("Invalid native message") }
    if kind == "shell-ready" { next(); return }
    if kind == "failure" { fail(value["error"] as? String ?? "Unknown worker error") }
    guard value["id"] as? String == runID else { fail("Late or unowned reply") }
    if kind == "progress" { return }
    if kind == "ready" {
      print("Ready: \(scenarios[scenarioIndex])")
      bootMilliseconds.append(milliseconds(since: bootStart))
      executionStart = .now
      armWatchdog(seconds: scenarios[scenarioIndex] == "infinite" ? 0.3 : 10)
      return
    }
    guard kind == "result", let answer = value["value"] as? [String: Any] else { fail("Missing result") }
    watchdog?.cancel()
    verify(answer, scenario: scenarios[scenarioIndex])
    results.append(["scenario": scenarios[scenarioIndex], "value": answer, "executionMilliseconds": milliseconds(since: executionStart)])
    next()
  }

  private func require(_ condition: Bool, _ contract: String) {
    guard condition else { fail(contract) }
    checks += 1
  }

  private func milliseconds(since instant: ContinuousClock.Instant) -> Double {
    let duration = instant.duration(to: .now).components
    return Double(duration.seconds)*1000 + Double(duration.attoseconds)/1e15
  }

  private func verify(_ value: [String: Any], scenario: String) {
    switch scenario {
    case "science":
      require(value["versions"] as? [String] == ["3.14.2", "2.4.6", "1.18.0", "1.14.0", "1.4.1"], "Pinned library versions")
      for (key, expected) in ["fraction": "-7/12", "power": "-8", "nested": "4/5", "derivative": "cos(x)", "integral": "1/3", "matrix": "-2"] {
        require(value[key] as? String == expected, key)
      }
      require(value["system"] as? [String: String] == ["x": "1", "y": "2"], "Linear system")
      let array = value["array"] as? [Double] ?? []
      require(array.count == 2 && abs(array[0]-0.2) < 1e-12 && abs(array[1]-0.6) < 1e-12, "NumPy solve")
      require(abs((value["quad"] as? Double ?? 0)-2) < 1e-12, "SciPy quadrature")
      require(abs((value["model"] as? Double ?? 0)-exp(-1.0)) < 1e-9, "SciPy dynamic model")
      require((value["precision"] as? String)?.hasPrefix("1.4142135623730950488016887242096980785696718753769") == true, "mpmath precision")
      require(value["environmentIsolated"] as? Bool == true, "Native environment is not Python input")
    case "isolation":
      for key in ["freshFilesystem", "freshGlobals", "packageInstallerAbsent", "systemCommandsAbsent"] { require(value[key] as? Bool == true, key) }
      require(value["answer"] as? Int == 42, "Recovery after worker termination")
      let network = value["network"] as? [String: Bool] ?? [:]
      for key in ["https", "file", "unknown", "traversal", "websocket"] { require(network[key] == true, "Denied access: " + key) }
      require(deniedPaths.count == 2, "Both unlisted resource requests were denied")
    case "failure":
      require(value["libraryError"] as? Bool == true, "Real library error: \(value)")
      require(value["afterError"] as? Int == 42, "Interpreter after library error")
      require(value["singularInverseAllFinite"] as? Bool == false, "Recorded WASM floating-point limitation")
      require(value["nonfiniteResultRejected"] as? Bool == true, "Nonfinite arrays cannot silently become ordinary JSON numbers")
    case "output":
      require(value["length"] as? Int == 1024 && value["truncated"] as? Bool == true, "Explicit output limit")
    default: fail("Unexpected result for " + scenario)
    }
  }

  private func next() {
    watchdog?.cancel()
    scenarioIndex += 1
    if scenarioIndex == scenarios.count { finish() }
    runID = UUID().uuidString
    bootStart = .now
    let script = "void window.startProbe('\(runID)', '\(scenarios[scenarioIndex])')"
    armWatchdog(seconds: 30)
    webView.evaluateJavaScript(script) { [weak self] _, error in
      if let error { self?.fail("Start failed: \(error)") }
    }
  }

  private func armWatchdog(seconds: Double) {
    watchdog?.cancel()
    watchdog = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
      guard let self else { return }
      if self.scenarioIndex >= 0 && self.scenarios[self.scenarioIndex] == "infinite" && seconds < 1 {
        let duration = self.executionStart.duration(to: .now)
        do { _ = try await self.webView.evaluateJavaScript("window.stopProbe()") }
        catch { self.fail("Worker termination failed: \(error)") }
        self.require(duration < .seconds(2), "Native watchdog remains responsive during infinite Python")
        self.results.append(["scenario": "infinite", "terminatedByParent": true, "executionMilliseconds": self.milliseconds(since: self.executionStart)])
        self.next()
      } else { self.fail("Deadline exceeded in scenario \(self.scenarioIndex); served: \(self.served.sorted())") }
    }
  }

  private func finish() -> Never {
    require(served.contains("pyodide.asm.wasm") && served.filter { $0.hasSuffix(".whl") }.count == 4, "Real bundled engine and four wheels were loaded")
    let report: [String: Any] = [
      "status": "passed", "checks": checks, "platform": ProcessInfo.processInfo.operatingSystemVersionString,
      "scope": "macOS WKWebView dependency proof; not physical iPad or release acceptance",
      "results": results, "servedResources": served.sorted(), "deniedPaths": deniedPaths,
      "bootMilliseconds": bootMilliseconds,
      "openGates": ["iPad recognition and resource acceptance", "hard WASM heap limit", "NotebookStore and Pencil integration", "Explicit nonfinite results; WASM does not preserve all native floating-point exceptions"],
    ]
    do {
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
      print("PASS: \(checks) computation dependency checks; \(output.path)")
      exit(0)
    } catch { fail("Could not save proof: \(error)") }
  }

  private func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

@main
private enum Main {
  @MainActor static func main() throws {
    guard CommandLine.arguments.count == 4 else { fatalError("Expected resource directory, harness directory, output JSON") }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let probe = try DependencyProbe(resources: URL(fileURLWithPath: CommandLine.arguments[1]), harness: URL(fileURLWithPath: CommandLine.arguments[2]), output: URL(fileURLWithPath: CommandLine.arguments[3]))
    probe.start()
    app.run()
    withExtendedLifetime(probe) {}
  }
}
