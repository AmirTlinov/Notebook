import XCTest
import WebKit
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
      ready = (try? await web.evaluateJavaScript("typeof window.voiceBegin === 'function'")) as? Bool == true
      if !ready { try await Task.sleep(for: .milliseconds(30)) }
    }
    XCTAssertTrue(ready)
    let available = try await web.evaluateJavaScript("window.isSecureContext && typeof RTCPeerConnection === 'function' && typeof navigator.mediaDevices?.getUserMedia === 'function'") as? Bool
    XCTAssertEqual(available, true)
    let idle = try await web.evaluateJavaScript("typeof peer === 'undefined' && typeof microphone === 'undefined'") as? Bool
    XCTAssertEqual(idle, true)
    _ = try await web.evaluateJavaScript("window.voiceEnd()")
    web.stopLoading()
  }
  func testUnavailableDictationPreservesEditableDraftAndNeverCreatesCallOrSubmission() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NotebookStore(root: directory), author = UUID(), queue = NotebookPersistenceQueue(store: store)
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let chat = NotebookChatController(persistence: queue, author: author) { _, _ in XCTFail("No audio or model request is authorized by the unavailable dictation action") }
    await chat.start(); chat.draft = "Мой вопрос"
    chat.voice.explainDictation()
    XCTAssertEqual(chat.draft, "Мой вопрос"); XCTAssertNil(chat.voice.activeID)
    XCTAssertEqual(chat.voice.error, NotebookVoiceController.dictationUnavailable)
    XCTAssertTrue(chat.jobs.isEmpty)
    chat.draft += " остаётся редактируемым"
    await chat.stop(); let saved = await queue.flush(); XCTAssertTrue(saved)
    XCTAssertEqual(try store.chatPanel(author: author).draft, chat.draft)
  }
}
