import AVFoundation
import Observation
import SwiftUI
import WebKit
import NotebookCore

/// The mounted call outlives the floating chat. Audio travels over WebRTC;
/// the existing paired Mac authorizes it and owns the same Codex task.
@MainActor @Observable final class NotebookVoiceController: NSObject {
  private(set) var activeID: UUID?
  private(set) var state: NotebookVoiceState?
  private(set) var changingMute = false
  private(set) var muted = false
  private(set) var mediaReady = false
  private(set) var ending = false
  private(set) var error: String?
  @ObservationIgnored weak var chat: NotebookChatController?
  @ObservationIgnored weak var host: UIView?
  @ObservationIgnored private var web: WKWebView?
  @ObservationIgnored private var lease: WebSurfaceLease?
  @ObservationIgnored private var poll: Task<Void, Never>?
  @ObservationIgnored private var deadline: Task<Void, Never>?
  @ObservationIgnored private var computer: UUID?
  @ObservationIgnored private var submitted = false
  @ObservationIgnored private var appliedAnswer = false

  static let dictationUnavailable = "Подключение Codex пока не поддерживает диктовку в черновик. Голосовой разговор доступен отдельно."
  func explainDictation() { error = Self.dictationUnavailable }
  func begin() async {
    guard activeID == nil, let chat, !chat.switchingComputer, chat.connected, let thread = chat.threadID, !chat.browsesChats, host != nil else { return }
    let id = UUID(); activeID = id; state = .init(id: id, threadID: thread); error = nil; muted = false; mediaReady = false; ending = false
    computer = chat.computerID; submitted = false; appliedAnswer = false
    guard await AVCaptureDevice.requestAccess(for: .audio) else {
      if activeID == id { error = "Разрешите Notebook доступ к микрофону в настройках iPad."; await end() }; return
    }
    guard activeID == id, !ending else { return }
    deadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(30)) } catch { return }
      guard let self, activeID == id, !mediaReady, !ending else { return }
      error = "Голосовое соединение не установлено за 30 секунд. Микрофон выключается."
      await end()
    }
    do {
      let acquired = try await SceneRenderResources.shared.acquireWebSurface(priority: .input)
      guard activeID == id, !ending, let host else { acquired.release(); return }
      lease = acquired
      let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
      configuration.allowsInlineMediaPlayback = true; configuration.mediaTypesRequiringUserActionForPlayback = []
      configuration.userContentController.add(self, name: "notebookVoice")
      let web = WKWebView(frame: host.bounds, configuration: configuration)
      web.isOpaque = false; web.backgroundColor = .clear; web.scrollView.backgroundColor = .clear
      web.autoresizingMask = [.flexibleWidth,.flexibleHeight]; web.navigationDelegate = self; web.uiDelegate = self
      self.web = web; host.addSubview(web)
      guard let resources = Bundle.main.url(forResource: "WebResources", withExtension: nil) else { throw CocoaError(.fileNoSuchFile) }
      web.loadFileURL(resources.appendingPathComponent("voice-shell.html"), allowingReadAccessTo: resources)
    } catch { if activeID == id { self.error = error.localizedDescription; await end() } }
  }
  private func startOffer(_ web: WKWebView, id: UUID) async {
    do {
      guard let sdp = try await web.callAsyncJavaScript("return await window.voiceBegin()", arguments: [:], in: nil, contentWorld: .page) as? String,
        activeID == id, !ending, let thread = state?.threadID, let chat, chat.connected else { throw NotebookTransportError.disconnected }
      submitted = true
      let receipt = try await chat.sessionCommand(.startVoice(.init(threadID: thread, sdp: sdp)), id: id, computer: computer)
      guard activeID == id, !ending else { return }
      guard receipt.state == .accepted else { throw NotebookPersistenceQueue.Failure(message: receipt.error ?? "Начало звонка ещё не подтверждено") }
      poll = Task { [weak self] in
        guard let self else { return }
        while activeID == id, !ending, !Task.isCancelled {
          do {
            guard case .voice(let next) = try await chat.directQuery(.voice(id)), next.id == id, next.threadID == thread else { throw NotebookTransportError.invalidAcknowledgement }
            guard activeID == id, !ending else { return }
            state = next
            if let sdp = next.sdp, !appliedAnswer {
              appliedAnswer = true
              _ = try await web.callAsyncJavaScript("await window.voiceAnswer(sdp)", arguments: ["sdp":sdp], in: nil, contentWorld: .page)
            }
            if !next.isActive { error = next.error; await end(); return }
            try await Task.sleep(for: .milliseconds(500))
          } catch { if activeID == id, !ending { self.error = error.localizedDescription; await end() }; return }
        }
      }
    } catch { if activeID == id, !ending { self.error = error.localizedDescription; await end() } }
  }
  func mute() async {
    guard activeID != nil, !ending, !changingMute, let web else { return }
    changingMute = true; defer { changingMute = false }
    let value = !muted
    do { _ = try await web.callAsyncJavaScript("window.voiceMute(value)", arguments: ["value": value], in: nil, contentWorld: .page); muted = value }
    catch { self.error = error.localizedDescription; await end() }
  }
  func connectionLost() {
    guard activeID != nil else { return }
    error = "Голосовое соединение прервано. Задача сохранена, микрофон выключается; автоматического звонка нет."
    Task { await end() }
  }
  func end() async {
    guard let id = activeID, !ending else { return }
    ending = true; poll?.cancel(); poll = nil; deadline?.cancel(); deadline = nil
    if let web {
      await web.setMicrophoneCaptureState(.none)
      _ = try? await web.callAsyncJavaScript("window.voiceEnd()", arguments: [:], in: nil, contentWorld: .page)
      web.configuration.userContentController.removeScriptMessageHandler(forName: "notebookVoice")
      web.stopLoading(); web.navigationDelegate = nil; web.uiDelegate = nil; web.removeFromSuperview(); self.web = nil
    }
    lease?.release(); lease = nil; mediaReady = false
    if submitted, let chat {
      do {
        let receipt = try await chat.sessionCommand(.stopVoice(id), computer: computer)
        if receipt.state == .uncertain { error = "Микрофон выключен. Завершение на Mac ещё не подтверждено; звонок не повторяется." }
      } catch { self.error = "Микрофон выключен. \(error.localizedDescription)" }
    }
    activeID = nil; ending = false; muted = false; submitted = false
  }
  func detach(_ host: UIView) { guard self.host === host else { return }; self.host = nil; Task { await end() } }
}
extension NotebookVoiceController: WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard webView === web, let id = activeID, !ending else { return }
    Task { await startOffer(webView, id: id) }
  }
  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
    action.navigationType == .other && action.request.url?.lastPathComponent == "voice-shell.html" && action.request.url?.isFileURL == true ? .allow : .cancel
  }
  func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
    webView === web && activeID != nil && !ending && frame.isMainFrame && type == .microphone
      && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .grant : .deny
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if webView === web { connectionLost() } }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.webView === web, message.frameInfo.isMainFrame, activeID != nil, !ending, let body = message.body as? [String:String] else { return }
    if body["type"] == "connection" {
      if body["state"] == "connected" { mediaReady = true; deadline?.cancel(); deadline = nil }
      else if ["failed","disconnected","closed"].contains(body["state"] ?? "") { connectionLost() }
    } else if body["type"] == "failed" { error = String((body["message"] ?? "Голос недоступен").prefix(2048)); Task { await end() } }
  }
}
struct NotebookVoiceSurface: UIViewRepresentable {
  let voice: NotebookVoiceController
  func makeUIView(context: Context) -> UIView { let view = UIView(); voice.host = view; return view }
  func updateUIView(_ view: UIView, context: Context) { }
  func makeCoordinator() -> NotebookVoiceController { voice }
  static func dismantleUIView(_ view: UIView, coordinator: NotebookVoiceController) { coordinator.detach(view) }
}
struct NotebookVoiceControls: View {
  @Bindable var voice: NotebookVoiceController
  var body: some View {
    if voice.activeID != nil {
      HStack(spacing: 8) {
        Image(systemName: voice.muted ? "mic.slash.fill" : "waveform").foregroundStyle(voice.mediaReady ? .green : .secondary)
        Text(voice.ending ? "Завершаю звонок…" : voice.mediaReady ? "Разговор с Codex" : "Соединяю…").font(.caption)
        Spacer(minLength: 0)
        Button { Task { await voice.mute() } } label: { Image(systemName: voice.muted ? "mic.fill" : "mic.slash").frame(width: 44,height: 44) }
          .accessibilityLabel(voice.muted ? "Включить микрофон" : "Выключить микрофон").disabled(voice.ending || voice.changingMute)
        Button { Task { await voice.end() } } label: { Image(systemName: "phone.down.fill").foregroundStyle(.red).frame(width: 44,height: 44) }
          .accessibilityLabel("Завершить голосовой разговор").disabled(voice.ending)
      }.padding(.leading,12)
    }
  }
}
