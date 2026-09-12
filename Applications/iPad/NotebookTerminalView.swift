import SwiftUI
import WebKit
import NotebookCore

struct NotebookRunPanel: View {
  @Bindable var runs: NotebookRunController
  let files: NotebookFileController
  let connected: Bool
  @State private var showsCommand = false
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Label("Терминал", systemImage: "terminal").font(.system(size: 12, weight: .medium))
        if let root = runs.selectedRoot {
          Text(URL(fileURLWithPath: root.root).lastPathComponent).font(.system(size: 12)).lineLimit(1).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        if runs.busy { ProgressView().controlSize(.mini) }
        Menu {
          if let project = files.window.project, project.roots.count > 1 {
            Picker("Папка терминала", selection: Binding(get: { runs.selectedRoot?.root ?? "" }, set: files.chooseRunRoot)) {
              ForEach(project.roots, id: \.self) { Text($0).tag($0) }
            }
          }
          Button("Команда проекта…", systemImage: "text.alignleft") { showsCommand = true }
            .disabled(runs.loadingCommand || runs.root == nil)
          Button(runs.record?.isActive == true ? "Перезапустить оболочку" : "Новая оболочка", systemImage: "terminal") {
            Task { await runs.openTerminal(restart: true) }
          }.disabled(!connected || runs.busy || runs.selectedRoot == nil)
          if runs.record?.isActive == true {
            Button("Завершить сеанс", systemImage: "stop.circle", role: .destructive) { Task { await runs.stopRun() } }
              .disabled(!connected || runs.busy)
          }
        } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36) }
          .accessibilityLabel("Действия терминала").accessibilityIdentifier("notebook-terminal-actions")
        Button { withAnimation(.easeInOut(duration: 0.18)) { files.toggleTerminal() } } label: {
          Image(systemName: "minus").frame(width: 36, height: 36)
        }.accessibilityLabel("Свернуть терминал").accessibilityIdentifier("notebook-terminal-collapse")
      }.padding(.horizontal, 12)
      if let root = runs.selectedRoot {
        NotebookTerminalView(runs: runs, root: root, connected: connected).id(root.id)
          .accessibilityIdentifier("notebook-terminal").frame(maxWidth: .infinity, maxHeight: .infinity)
          .overlay {
            if !runs.busy, !runs.loadingCommand, runs.record?.isActive != true {
              VStack(spacing: 8) {
                if let record = runs.record {
                  Text(record.error ?? "Сеанс завершён · код \(record.exitCode ?? 0)").font(.caption).lineLimit(2)
                }
                Button("Открыть оболочку", systemImage: "terminal") { Task { await runs.openTerminal() } }
                  .font(.system(size: 13)).padding(10)
                  .background(.regularMaterial, in: Capsule())
                  .disabled(!connected).accessibilityIdentifier("notebook-terminal-open-shell")
              }.padding(12).foregroundStyle(.white)
            }
          }
        HStack(spacing: 0) {
          Text(connected ? (runs.record?.phase == .starting ? "Открывается на Mac…" : "zsh · Mac") : "Mac не в сети")
            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
          Spacer(minLength: 2)
          terminalKey("Esc", bytes: [27])
          terminalKey("Tab", bytes: [9])
          terminalKey("↑", bytes: [27, 91, 65])
          terminalKey("↓", bytes: [27, 91, 66])
          terminalKey("Ctrl-C", bytes: [3])
        }.padding(.horizontal, 12)
        if let error = runs.error { Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2).padding(.horizontal, 12) }
        if runs.inputBlocked {
          Button("Продолжить ввод без повтора неподтверждённого") { runs.continueInput() }
            .font(.caption2).disabled(!connected).padding(.horizontal, 12)
        }
      } else {
        Text("Выберите проект Mac в чате.").font(.callout).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .accessibilityElement(children: .contain).accessibilityIdentifier("notebook-terminal-panel")
    .sheet(isPresented: $showsCommand) {
      NavigationStack {
        Form {
          TextField("Команда на Mac", text: $runs.command, axis: .vertical)
            .font(.system(size: 14, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("notebook-run-command")
          if let root = runs.selectedRoot { Text(root.root).font(.caption).foregroundStyle(.secondary) }
          Button(runs.record?.isActive == true ? "Завершить текущий сеанс и запустить" : "Запустить команду") {
            Task { await runs.start(restart: runs.record != nil); showsCommand = false }
          }.disabled(!connected || runs.busy || runs.loadingCommand || runs.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("notebook-run-start")
        }
        .navigationTitle("Команда проекта").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showsCommand = false } } }
      }.presentationDetents([.medium])
    }
  }
  private func terminalKey(_ title: String, bytes: [UInt8]) -> some View {
    Button(title) { runs.input(Data(bytes)) }.font(.system(size: 11, design: .monospaced))
      .frame(minWidth: 32, minHeight: 32).disabled(!runs.canInput)
      .accessibilityLabel(title == "Ctrl-C" ? "Прервать команду терминала" : title)
  }
}

struct NotebookTerminalView: UIViewRepresentable {
  let runs: NotebookRunController
  let root: NotebookFileAddress
  let connected: Bool
  func makeCoordinator() -> Coordinator { Coordinator(runs: runs, root: root) }
  func makeUIView(context: Context) -> UIView { let view = UIView(); context.coordinator.mount(view); return view }
  func updateUIView(_ view: UIView, context: Context) { context.coordinator.connected(connected, blocked: runs.inputBlocked) }
  static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.close() }
  @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var runs: NotebookRunController?
    let root: NotebookFileAddress
    var web: WKWebView?, lease: WebSurfaceLease?, preparation: Task<Void, Never>?
    var reader: UUID?, closed = false, ready = false, online = false
    var lastActive: Bool?
    var restoring = true, blocked = false
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
      ready = true; connected(online, blocked: blocked, force: true)
      reader = runs?.attach(root) { [weak self] output, reset in
        guard let self, !closed, let web else { throw NotebookTransportError.disconnected }
        if reset { restoring = true }
        let active = output.record?.phase == .running && (!restoring || !output.more)
        guard reset || !output.data.isEmpty || lastActive != active else { return }
        _ = try await web.callAsyncJavaScript("await window.writeOutput(data, reset, lost, active, replay)", arguments: [
          "data": output.data.base64EncodedString(), "reset": reset, "lost": output.lostPrefix, "active": active, "replay": restoring
        ], in: nil, contentWorld: .page)
        lastActive = active; restoring = restoring && output.more
      }
    }
    func connected(_ value: Bool, blocked: Bool = false, force: Bool = false) {
      guard force || value != online || blocked != self.blocked else { return }
      online = value; self.blocked = blocked
      guard ready, let web, !closed else { return }
      Task { _ = try? await web.callAsyncJavaScript("window.setConnected(value)", arguments: ["value": value && !blocked], in: nil, contentWorld: .page) }
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
      web?.evaluateJavaScript("window.closeTerminal?.()")
      web?.stopLoading(); web?.navigationDelegate = nil; web?.removeFromSuperview(); web = nil
      lease?.release(); lease = nil
    }
  }
}
