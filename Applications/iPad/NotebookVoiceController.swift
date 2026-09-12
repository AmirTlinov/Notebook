import AVFoundation
import Observation
import SwiftUI
import WebKit
import NotebookCore

/// The mounted call outlives the floating chat. Audio travels over WebRTC;
/// the existing paired Mac authorizes it and owns the same Codex task.
@MainActor @Observable final class NotebookVoiceController: NSObject {
  enum Method: String, CaseIterable { case dictation, conversation
    var label: String { self == .dictation ? "Диктовка · текстовый ответ" : "Живой разговор" }
  }
  enum Phase { case off, preparing, waiting, listening, processing, speaking, muted }
  var method = Method(rawValue: UserDefaults.standard.string(forKey: "notebook.voice.method") ?? "") ?? .conversation {
    didSet { UserDefaults.standard.set(method.rawValue, forKey: "notebook.voice.method") }
  }
  var language = UserDefaults.standard.string(forKey: "notebook.voice.language") ?? NotebookWakeRecognizer.preferredLanguage {
    didSet {
      UserDefaults.standard.set(language, forKey: "notebook.voice.language")
      address = UserDefaults.standard.string(forKey: "notebook.voice.address." + language) ?? NotebookWakeAddress.localAddress(language: language)
    }
  }
  var address = "" {
    didSet { UserDefaults.standard.set(String(address.prefix(48)), forKey: "notebook.voice.address." + language) }
  }
  override init() {
    super.init()
    address = UserDefaults.standard.string(forKey: "notebook.voice.address." + language) ?? NotebookWakeAddress.localAddress(language: language)
  }
  private(set) var phase: Phase = .off
  private(set) var taskTitle = ""
  private(set) var captureID: UUID?
  var capturing: Bool { captureID != nil }
  var status: String {
    if ending { return muted ? "Микрофон выключен · завершаю на Mac…" : "Выключаю микрофон…" }
    switch phase {
    case .off: return "Микрофон выключен"
    case .preparing: return "Подготовка микрофона…"
    case .waiting: return "Ожидаю «\(address.isEmpty ? "GPT" : address + ", GPT")»"
    case .listening: return "Слушаю"
    case .processing: return "Обрабатываю обращение…"
    case .speaking: return "GPT отвечает"
    case .muted: return "Микрофон выключен"
    }
  }
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
  @ObservationIgnored private var endConfirmation: Task<Void, Never>?
  @ObservationIgnored private var deadline: Task<Void, Never>?
  @ObservationIgnored private var computer: UUID?
  @ObservationIgnored private var wake: NotebookWakeRecognizer?
  @ObservationIgnored private var waiting = false
  @ObservationIgnored private var agentSpeaking = false
  @ObservationIgnored private var submitted = false
  @ObservationIgnored private var appliedAnswer = false

  static let dictationUnavailable = "Подключение Codex пока не поддерживает диктовку в черновик. Голосовой разговор доступен отдельно."
  func explainDictation() { if !capturing { method = .dictation }; error = Self.dictationUnavailable }
  func dismissError() { error = nil }
  func begin() async { guard !capturing else { return }; method = .conversation; await prepare(waiting: false) }
  func arm() async {
    guard method == .conversation else { explainDictation(); return }
    await prepare(waiting: true)
  }
  private func prepare(waiting: Bool) async {
    guard captureID == nil, let chat, !chat.switchingComputer, chat.connected, let thread = chat.threadID, !chat.browsesChats, host != nil else { return }
    let id = UUID(); captureID = id; activeID = waiting ? nil : id; state = .init(id: id, threadID: thread); taskTitle = chat.taskTitle; phase = .preparing; self.waiting = waiting; error = nil; muted = false; mediaReady = false; ending = false
    computer = chat.computerID; submitted = false; appliedAnswer = false
    if waiting {
      do {
        let wake = try NotebookWakeRecognizer(language: language, address: address,
          activated: { [weak self] frame in
            guard let self, captureID == id, self.waiting, !ending, let web = self.web else { return }
            self.waiting = false; self.wake = nil; activeID = id; phase = .processing
            startDeadline(id)
            Task { await startOffer(web, id: id, start: frame) }
          }, failed: { [weak self] message in
            guard let self, captureID == id, !ending else { return }
            error = message; Task { await end() }
          })
        self.wake = wake
        guard await wake.authorize() else { throw NotebookPersistenceQueue.Failure(message: "Для локального обращения разрешите распознавание речи в настройках iPad. Звук не передаётся в Apple.") }
        guard captureID == id, !ending else { return }
        wake.start()
      } catch { if captureID == id { self.error = error.localizedDescription; await end() }; return }
    }
    guard await AVCaptureDevice.requestAccess(for: .audio) else {
      if captureID == id { error = "Разрешите Notebook доступ к микрофону в настройках iPad."; await end() }; return
    }
    guard captureID == id, !ending else { return }
    startDeadline(id)
    do {
      let acquired = try await SceneRenderResources.shared.acquireWebSurface(priority: .input)
      guard captureID == id, !ending, let host else { acquired.release(); return }
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
    } catch { if captureID == id { self.error = error.localizedDescription; await end() } }
  }
  private func startDeadline(_ id: UUID) {
    deadline?.cancel()
    deadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(30)) } catch { return }
      guard let self, captureID == id, !mediaReady, !ending else { return }
      error = "Голосовое соединение не установлено за 30 секунд. Микрофон выключается."
      await end()
    }
  }
  private func startOffer(_ web: WKWebView, id: UUID, start: Int) async {
    do {
      guard let sdp = try await web.callAsyncJavaScript("return await window.voiceOffer(start)", arguments: ["start": start], in: nil, contentWorld: .page) as? String,
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
    guard capturing, !ending, !changingMute else { return }
    if activeID == nil { await end(); return }
    guard let web else { return }
    changingMute = true; defer { changingMute = false }
    let id = captureID, value = !muted
    do { _ = try await web.callAsyncJavaScript("await window.voiceMute(value)", arguments: ["value": value], in: nil, contentWorld: .page); guard captureID == id, !ending else { return }; muted = value; phase = value ? .muted : .listening }
    catch { self.error = error.localizedDescription; await end() }
  }
  func connectionLost() {
    guard capturing else { return }
    error = "Голосовое соединение прервано. Задача сохранена, микрофон выключается; автоматического звонка нет."
    Task { await end() }
  }
  func end() async {
    guard let id = captureID, !ending else { return }
    ending = true; wake?.stop(); wake = nil; waiting = false; poll?.cancel(); poll = nil; deadline?.cancel(); deadline = nil
    if let web {
      // Retire capture before waiting for the network. Navigation also destroys
      // the audio graph if its JS process cannot complete voiceEnd's promise.
      web.setMicrophoneCaptureState(.none, completionHandler: nil)
      web.evaluateJavaScript("window.voiceEnd()", completionHandler: nil)
      web.configuration.userContentController.removeScriptMessageHandler(forName: "notebookVoice")
      web.stopLoading(); web.loadHTMLString("", baseURL: nil)
      web.navigationDelegate = nil; web.uiDelegate = nil; web.removeFromSuperview(); self.web = nil
    }
    lease?.release(); lease = nil; mediaReady = false; muted = true; phase = .off; agentSpeaking = false
    guard submitted, let chat else { finishEnd(id); return }
    do {
      let receipt = try await chat.sessionCommand(.stopVoice(id), computer: computer)
      if receipt.state == .accepted { finishEnd(id); return }
    } catch {
      self.error = "Микрофон выключен. Mac пока не подтвердил завершение: \(error.localizedDescription)"
    }
    endConfirmation = Task { [weak self] in
      while let self, !Task.isCancelled, captureID == id, ending {
        if chat.connected, chat.computerID == computer,
          case .voice(let value) = try? await chat.directQuery(.voice(id)), value.id == id, value.phase == .ended {
          finishEnd(id); return
        }
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
    }
  }
  private func finishEnd(_ id: UUID) {
    guard captureID == id else { return }
    state?.phase = .ended; state?.sdp = nil
    activeID = nil; captureID = nil; phase = .off; ending = false; muted = false; submitted = false
    endConfirmation?.cancel(); endConfirmation = nil
  }
  func shutdown() async { await end(); endConfirmation?.cancel(); endConfirmation = nil }
  func detach(_ host: UIView) { guard self.host === host else { return }; self.host = nil; Task { await end() } }
}
extension NotebookVoiceController: WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard webView === web, let id = captureID, !ending else { return }
    let awaitsAddress = waiting
    Task {
      do {
        _ = try await webView.callAsyncJavaScript("return await window.voicePrepare()", arguments: [:], in: nil, contentWorld: .page)
        guard captureID == id, !ending else { return }
        if awaitsAddress { if waiting { phase = .waiting; deadline?.cancel(); deadline = nil } }
        else if activeID == id { phase = .processing; await startOffer(webView, id: id, start: 0) }
      } catch { if captureID == id, !ending { self.error = error.localizedDescription; await end() } }
    }
  }
  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
    action.navigationType == .other && action.request.url?.lastPathComponent == "voice-shell.html" && action.request.url?.isFileURL == true ? .allow : .cancel
  }
  func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
    webView === web && captureID != nil && !ending && frame.isMainFrame && type == .microphone
      && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .grant : .deny
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if webView === web { connectionLost() } }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.webView === web, message.frameInfo.isMainFrame, captureID != nil, !ending, let body = message.body as? [String:Any] else { return }
    if body["type"] as? String == "connection" {
      if body["state"] as? String == "connected" { mediaReady = true; phase = .listening; deadline?.cancel(); deadline = nil }
      else if ["failed","disconnected","closed"].contains(body["state"] as? String ?? "") { connectionLost() }
    } else if body["type"] as? String == "pcm", waiting,
      let data = body["data"] as? String, data.count <= 90000, let pcm = Data(base64Encoded: data),
      let frame = body["start"] as? Int, let rate = body["rate"] as? Double {
      wake?.append(data: pcm, frame: frame, sampleRate: rate)
    } else if body["type"] as? String == "output", let speaking = body["speaking"] as? Bool {
      agentSpeaking = speaking
      if !muted { phase = speaking ? .speaking : .listening }
    } else if body["type"] as? String == "input", !muted, mediaReady, !agentSpeaking, let speaking = body["speaking"] as? Bool {
      phase = speaking ? .listening : .processing
    } else if body["type"] as? String == "processing", !muted, !agentSpeaking { phase = .processing }
    else if body["type"] as? String == "failed" { error = String((body["message"] as? String ?? "Голос недоступен").prefix(2048)); Task { await end() } }
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
  @State private var showingText = false
  var body: some View {
    if voice.capturing {
      HStack(spacing: 8) {
        Image(systemName: voice.muted ? "mic.slash.fill" : "waveform").foregroundStyle(voice.mediaReady ? .green : .secondary)
        Text(voice.status).font(.caption).lineLimit(2)
        Spacer(minLength: 0)
        Button { Task { await voice.mute() } } label: { Image(systemName: voice.muted ? "mic.fill" : "mic.slash").frame(width: 44,height: 44).contentShape(Rectangle()) }
          .accessibilityLabel(voice.muted ? "Включить микрофон" : "Выключить микрофон").disabled(voice.ending || voice.changingMute)
        if voice.activeID != nil {
        Button { showingText = true } label: { Image(systemName: "text.bubble").frame(width: 36, height: 44).contentShape(Rectangle()) }
          .accessibilityLabel("Текст голосового разговора")
        Button { Task { await voice.end() } } label: { Image(systemName: "phone.down.fill").foregroundStyle(.red).frame(width: 44,height: 44).contentShape(Rectangle()) }
          .accessibilityLabel("Завершить голосовой разговор").disabled(voice.ending)
        }
      }.padding(.leading,12)
        .popover(isPresented: $showingText) {
          ScrollView {
            VStack(alignment: .leading, spacing: 12) {
              Text(voice.taskTitle).font(.headline)
              if let text = voice.state?.userText, !text.isEmpty { Text(text).foregroundStyle(.secondary) }
              if let text = voice.state?.assistantText, !text.isEmpty { Text(text) }
              Button("Готово") { showingText = false }
            }.textSelection(.enabled).padding(18)
          }.frame(width: 310, height: 260).presentationCompactAdaptation(.popover)
        }
    }
  }
}
