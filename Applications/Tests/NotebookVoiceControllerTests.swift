import XCTest
import WebKit
import AVFoundation
import NotebookCore
@testable import Notebook

@MainActor final class NotebookVoiceControllerTests: XCTestCase {
  func testBundledWebRTCPageDoesNotStartCaptureWhileMounted() async throws {
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: .init(x: 0, y: 0, width: 1, height: 1), configuration: config)
    let resources = try XCTUnwrap(Bundle.main.url(forResource: "WebResources", withExtension: nil))
    web.loadFileURL(resources.appendingPathComponent("voice-shell.html"), allowingReadAccessTo: resources)
    let deadline = ContinuousClock.now + .seconds(5)
    var ready = false
    while !ready, .now < deadline {
      ready = (try? await web.evaluateJavaScript("typeof window.voicePrepare === 'function'")) as? Bool == true
      if !ready { try await Task.sleep(for: .milliseconds(30)) }
    }
    XCTAssertTrue(ready)
    let available = try await web.evaluateJavaScript("window.isSecureContext && typeof RTCPeerConnection === 'function' && typeof navigator.mediaDevices?.getUserMedia === 'function'") as? Bool
    XCTAssertEqual(available, true)
    let idle = try await web.evaluateJavaScript("typeof peer === 'undefined' && typeof microphone === 'undefined'") as? Bool
    XCTAssertEqual(idle, true)
    _ = try await web.callAsyncJavaScript("await window.voiceEnd()", arguments: [:], in: nil, contentWorld: .page)
    web.stopLoading()
  }
  func testActualWebAudioGateKeepsWaitingLocalAndMuteReleasesTheMicrophoneWithoutASecondPeer() async throws {
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .denied else {
      XCTFail("Synthetic WebAudio requires denied hardware capture: simctl privacy <test-device> revoke microphone com.amirtlinov.notebook")
      return
    }
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
    config.allowsInlineMediaPlayback = true; config.mediaTypesRequiringUserActionForPlayback = []
    let sink = VoiceMessages(); config.userContentController.add(sink, name: "notebookVoice")
    let web = WKWebView(frame: .init(x: 0, y: 0, width: 240, height: 100), configuration: config)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene); window.rootViewController = UIViewController(); window.rootViewController?.view.addSubview(web); window.isHidden = false
    defer { web.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "notebookVoice"); window.isHidden = true; window.rootViewController = nil }
    let resources = try XCTUnwrap(Bundle.main.url(forResource: "WebResources", withExtension: nil))
    web.loadFileURL(resources.appendingPathComponent("voice-shell.html"), allowingReadAccessTo: resources)
    let deadline = ContinuousClock.now + .seconds(5)
    while (try? await web.evaluateJavaScript("typeof window.voicePrepare === 'function'")) as? Bool != true, .now < deadline {
      try await Task.sleep(for: .milliseconds(30))
    }
    _ = try await web.callAsyncJavaScript("""
      window.captures=0;window.synthetic=[];
      navigator.mediaDevices.getUserMedia=async()=>{
        captures++;const ac=new AudioContext({sampleRate:24000}),dest=ac.createMediaStreamDestination(),osc=ac.createOscillator();
        osc.connect(dest);osc.start();await ac.resume();synthetic.push(ac);return dest.stream;
      };
      await window.voicePrepare();
      """, arguments: [:], in: nil, contentWorld: .page)
    XCTAssertGreaterThan(sink.pcm, 0)
    let local = try await web.evaluateJavaScript("typeof peer==='undefined' && captures===1") as? Bool
    XCTAssertEqual(local, true, "Before the address there is no connection carrying ambient speech")
    let offer = try await web.callAsyncJavaScript("return await window.voiceOffer(0)", arguments: [:], in: nil, contentWorld: .page) as? String
    XCTAssertTrue(offer?.contains("m=audio") == true)
    _ = try await web.evaluateJavaScript("window.originalPeer=peer;window.originalTrack=microphone.getAudioTracks()[0]")
    _ = try await web.evaluateJavaScript("window.voiceSpeakerMute(true)")
    let outputOff = try await web.evaluateJavaScript("document.getElementById('speaker').muted && originalTrack.readyState==='live' && captures===1 && peer===originalPeer") as? Bool
    XCTAssertEqual(outputOff, true, "Output mute must not stop the microphone or replace the existing call")
    _ = try await web.evaluateJavaScript("window.voiceSpeakerMute(false)")
    let outputOn = try await web.evaluateJavaScript("!document.getElementById('speaker').muted && captures===1 && peer===originalPeer") as? Bool
    XCTAssertEqual(outputOn, true)
    _ = try await web.callAsyncJavaScript("await window.voiceMute(true)", arguments: [:], in: nil, contentWorld: .page)
    let off = try await web.evaluateJavaScript("microphone===null && originalTrack.readyState==='ended' && peer===originalPeer") as? Bool
    XCTAssertEqual(off, true, "Mute stops capture, not just track transmission")
    let count = sink.pcm; try await Task.sleep(for: .milliseconds(250)); XCTAssertEqual(sink.pcm, count)
    _ = try await web.callAsyncJavaScript("await window.voiceMute(false)", arguments: [:], in: nil, contentWorld: .page)
    let resumed = try await web.evaluateJavaScript("captures===2 && peer===originalPeer") as? Bool
    XCTAssertEqual(resumed, true)
    let repeatRejected = try await web.callAsyncJavaScript("try { await window.voiceOffer(0); return false } catch { return true }", arguments: [:], in: nil, contentWorld: .page) as? Bool
    XCTAssertEqual(repeatRejected, true)
    _ = try await web.callAsyncJavaScript("await window.voiceEnd();for(const ac of synthetic)await ac.close()", arguments: [:], in: nil, contentWorld: .page)
    let released = try await web.evaluateJavaScript("peer===null && context===null && microphone===null && gate===null") as? Bool
    XCTAssertEqual(released, true); XCTAssertTrue(sink.errors.isEmpty, "\(sink.errors)")
  }
  @MainActor private final class VoiceMessages: NSObject, WKScriptMessageHandler {
    var pcm = 0; var errors: [String] = []
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
      guard let value = message.body as? [String: Any] else { return }
      if value["type"] as? String == "pcm" { pcm += 1 }
      if value["type"] as? String == "failed" { errors.append(value["message"] as? String ?? "failed") }
    }
  }
  func testRetiredDictationPreferenceCannotBlockAnExplicitVoiceActionOrLoseTheDraft() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NotebookStore(root: directory), author = UUID(), queue = NotebookPersistenceQueue(store: store)
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    UserDefaults.standard.set("dictation", forKey: "notebook.voice.method")
    let chat = NotebookChatController(persistence: queue, author: author) { _, _ in XCTFail("An unavailable voice action cannot send work") }
    await chat.start(); chat.draft = "Мой вопрос"
    XCTAssertNil(UserDefaults.standard.object(forKey: "notebook.voice.method"))
    let host = UIView(); chat.voice.host = host
    await chat.voice.arm()
    XCTAssertFalse(chat.voice.capturing)
    XCTAssertEqual(chat.draft, "Мой вопрос"); XCTAssertNil(chat.voice.activeID)
    XCTAssertEqual(chat.voice.error, "Выберите чат для голосового разговора.")
    chat.select(.init(id: UUID().uuidString, title: "Моя задача", cwd: "/fixture"))
    await chat.voice.arm()
    XCTAssertEqual(chat.voice.error, "Подключите Mac, чтобы начать голосовой разговор.")
    XCTAssertTrue(chat.jobs.isEmpty)
    chat.draft += " остаётся редактируемым"
    await chat.stop(); let saved = await queue.flush(); XCTAssertTrue(saved)
    XCTAssertEqual(try store.chatPanel(author: author).draft, chat.draft)
  }

  func testFailedWakePreparationReleasesCaptureButRetainsTheReasonAcrossCollapseAndEnd() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NotebookStore(root: directory), author = UUID(), peer = UUID(), thread = UUID().uuidString, queue = NotebookPersistenceQueue(store: store)
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    var chat: NotebookChatController!
    chat = .init(persistence: queue, author: author) { envelope, _ in
      guard case .request(let query) = envelope.body else { return }
      if case .job = query { XCTFail("Failed local preparation must never start a call or send a message") }
      chat.receive(.init(id: envelope.id, body: .reply(.failure("No remote work in this fixture"))), peerID: peer)
    }
    await chat.start(); await chat.connect(peer)
    chat.select(.init(id: thread, title: "Моя задача", cwd: "/fixture"))
    chat.draft = "Неотправленный вопрос"
    let host = UIView(); chat.voice.host = host
    let language = chat.voice.language, address = chat.voice.address
    defer { chat.voice.language = language; chat.voice.address = address }
    chat.voice.language = "zz-ZZ"
    await chat.voice.arm()
    let reason = try XCTUnwrap(chat.voice.error)
    XCTAssertTrue(reason.contains("недоступно локальное распознавание"), reason)
    XCTAssertFalse(chat.voice.capturing); XCTAssertNil(chat.voice.activeID)
    XCTAssertEqual(chat.voice.phase, .off); XCTAssertFalse(chat.voice.ending)
    XCTAssertTrue(host.subviews.isEmpty); XCTAssertTrue(chat.jobs.isEmpty)
    chat.expanded = true; chat.expanded = false
    await chat.voice.end()
    XCTAssertEqual(chat.voice.error, reason, "Resource cleanup cannot dismiss an unacknowledged startup failure")
    XCTAssertEqual(chat.draft, "Неотправленный вопрос"); XCTAssertEqual(chat.threadID, thread)
    chat.voice.dismissError(); XCTAssertNil(chat.voice.error)
    await chat.stop()
    let saved = await queue.flush(); XCTAssertTrue(saved)
  }
}
