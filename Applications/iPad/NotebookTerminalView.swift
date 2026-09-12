import SwiftUI
import WebKit
import NotebookCore

struct NotebookRunPanel: View {
  @Bindable var runs: NotebookRunController
  let files: NotebookFileController
  let connected: Bool
  var body: some View {
    VStack(spacing: 0) {
      if let root = runs.selectedRoot {
        if let project = files.window.project, project.roots.count > 1 {
          Picker("Папка запуска", selection: Binding(get: { root.root }, set: files.chooseRunRoot)) {
            ForEach(project.roots, id: \.self) { Text($0).tag($0) }
          }.font(.caption).padding(.horizontal, 12)
        }
        HStack(spacing: 8) {
          TextField("python3 main.py", text: $runs.command).font(.system(size: 13, design: .monospaced))
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("notebook-run-command").disabled(runs.loadingCommand)
          Button { Task { await runs.start(restart: runs.record != nil) } } label: {
            Image(systemName: runs.record == nil ? "play.fill" : "arrow.clockwise").frame(width: 40, height: 40)
          }.accessibilityLabel(runs.record == nil ? "Запустить" : "Перезапустить")
            .accessibilityIdentifier("notebook-run-start").disabled(!connected || runs.busy || runs.command.isEmpty)
          if runs.record?.isActive == true {
            Button { Task { await runs.stopRun() } } label: { Image(systemName: "stop.fill").frame(width: 40, height: 40) }
              .accessibilityLabel("Остановить процесс").accessibilityIdentifier("notebook-run-stop").disabled(!connected || runs.busy)
          }
        }.padding(.horizontal, 12)
        NotebookTerminalView(runs: runs, root: root, connected: connected).id(root.id)
          .accessibilityIdentifier("notebook-terminal").frame(maxWidth: .infinity, maxHeight: .infinity)
        HStack {
          Text(status).lineLimit(2)
          Spacer(minLength: 4)
          if runs.record?.isActive == true {
            Button("Ctrl-C") { runs.input(Data([3])) }.disabled(!connected || runs.inputBlocked)
              .accessibilityLabel("Прервать команду терминала")
            Button("↵") { runs.input(Data([13])) }.disabled(!connected || runs.inputBlocked)
              .accessibilityLabel("Ввод в терминале")
          }
        }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
        if let error = runs.error { Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(3).padding(.horizontal, 12) }
        if runs.inputBlocked { Button("Продолжить ввод без повтора неподтверждённого") { runs.continueInput() }.font(.caption2).disabled(!connected) }
      } else {
        ContentUnavailableView("Терминал проекта", systemImage: "terminal", description: Text("Выберите проект подключённого Mac."))
      }
    }
  }
  private var status: String {
    guard connected else { return "Mac не подключён · процесс не остановлен" }
    guard let record = runs.record else { return "Команда выполняется на Mac, не в модели" }
    switch record.phase {
    case .starting: return "Запуск…"
    case .running: return "Выполняется на Mac"
    case .exited: return "Завершён · код \(record.exitCode ?? 0)"
    case .interrupted: return record.error ?? "Прерван · повторного запуска нет"
    }
  }
}

struct NotebookTerminalView: UIViewRepresentable {
  let runs: NotebookRunController
  let root: NotebookFileAddress
  let connected: Bool
  func makeCoordinator() -> Coordinator { Coordinator(runs: runs, root: root) }
  func makeUIView(context: Context) -> UIView { let view = UIView(); context.coordinator.mount(view); return view }
  func updateUIView(_ view: UIView, context: Context) { context.coordinator.connected(connected) }
  static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.close() }
  @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var runs: NotebookRunController?
    let root: NotebookFileAddress
    var web: WKWebView?, lease: WebSurfaceLease?, preparation: Task<Void, Never>?
    var reader: UUID?, closed = false, ready = false, online = false
    var lastActive: Bool?
    init(runs: NotebookRunController, root: NotebookFileAddress) { self.runs = runs; self.root = root }
    func mount(_ view: UIView) {
      preparation = Task { [weak self, weak view] in
        do {
          let lease = try await SceneRenderResources.shared.acquireWebSurface(priority: .input)
          guard let self, let view, !closed, !Task.isCancelled else { lease.release(); return }
          self.lease = lease
          let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
          configuration.userContentController.add(self, name: "notebookTerminal")
          let web = WKWebView(frame: view.bounds, configuration: configuration)
          web.autoresizingMask = [.flexibleWidth, .flexibleHeight]; web.navigationDelegate = self
          web.scrollView.isScrollEnabled = false; web.isOpaque = true
          self.web = web; view.addSubview(web)
          guard let resources = Bundle.main.url(forResource: "WebResources", withExtension: nil) else { runs?.unavailable("Ресурсы терминала отсутствуют в приложении."); close(); return }
          web.loadFileURL(resources.appendingPathComponent("terminal-shell.html"), allowingReadAccessTo: resources)
        } catch { self?.runs?.unavailable(error.localizedDescription) }
      }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      guard !closed, webView === web else { return }
      ready = true; connected(online, force: true)
      reader = runs?.attach(root) { [weak self] output, reset in
        guard let self, !closed, let web else { throw NotebookTransportError.disconnected }
        let active = output.record?.isActive == true && online
        guard reset || !output.data.isEmpty || lastActive != active else { return }
        _ = try await web.callAsyncJavaScript("await window.writeOutput(data, reset, lost, active)", arguments: [
          "data": output.data.base64EncodedString(), "reset": reset, "lost": output.lostPrefix, "active": active
        ], in: nil, contentWorld: .page)
        lastActive = active
      }
    }
    func connected(_ value: Bool, force: Bool = false) {
      guard force || value != online else { return }
      online = value
      guard ready, let web, !closed else { return }
      Task { _ = try? await web.callAsyncJavaScript("window.setConnected(value)", arguments: ["value": value], in: nil, contentWorld: .page) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
      action.navigationType == .other && action.request.url?.lastPathComponent == "terminal-shell.html" && action.request.url?.isFileURL == true ? .allow : .cancel
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
      guard !closed, message.webView === web, message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
      if body["type"] as? String == "input", let value = body["data"] as? String, value.utf8.count <= 10_924,
        let bytes = Data(base64Encoded: value), bytes.count <= 8192, online { runs?.input(bytes) }
      else if body["type"] as? String == "size", let columns = body["columns"] as? Int, let rows = body["rows"] as? Int { runs?.size(columns: columns, rows: rows) }
    }
    func close() {
      closed = true; preparation?.cancel(); preparation = nil
      if let reader { runs?.detach(reader) }; reader = nil
      web?.configuration.userContentController.removeScriptMessageHandler(forName: "notebookTerminal")
      web?.stopLoading(); web?.navigationDelegate = nil; web?.removeFromSuperview(); web = nil
      lease?.release(); lease = nil
    }
  }
}
