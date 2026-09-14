import Foundation
import Testing
import NotebookScriptProtocol
import NotebookScriptWorker

struct NotebookQuickJSCancellationTests {
  private final class Probe: @unchecked Sendable {
    let lock = NSLock()
    var hostReply: (@Sendable (NotebookWorkerReply) -> Void)?
    var result: NotebookWorkerReply?
    var completionCount = 0
    func accept(_ reply: @escaping @Sendable (NotebookWorkerReply) -> Void) { lock.withLock { hostReply = reply } }
    func complete(_ reply: NotebookWorkerReply) { lock.withLock { result = reply; completionCount += 1 } }
    var waiting: Bool { lock.withLock { hostReply != nil } }
    var reply: NotebookWorkerReply? { lock.withLock { result } }
    func answerLate() { lock.withLock { hostReply }?(.init(value: Data("42".utf8))) }
  }

  @Test func cancelWakesAHostPromiseWithoutWaitingForItsReply() async throws {
    let probe = Probe()
    let engine = NotebookQuickJSEngine(bootstrap: "") { _, _, done in probe.accept(done) }
    engine.start(code: "await globalThis.__nbHost('hold',{}); return 42;", arguments: Data("{}".utf8)) { probe.complete($0) }
    let admissionDeadline = ContinuousClock.now + .seconds(2)
    while !probe.waiting, ContinuousClock.now < admissionDeadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(probe.waiting && probe.reply == nil)
    engine.cancel()
    let cancelDeadline = ContinuousClock.now + .seconds(1)
    while probe.reply == nil, ContinuousClock.now < cancelDeadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(probe.reply?.code == "script_interrupted")
    #expect(probe.reply?.value == nil)
    probe.answerLate()
    try await Task.sleep(for: .milliseconds(20))
    #expect(probe.lock.withLock { probe.completionCount } == 1)
  }

  @Test func cancelBeforeTheInterpreterStartsIsNotLost() async throws {
    let probe = Probe()
    let engine = NotebookQuickJSEngine(bootstrap: "") { _, _, done in probe.accept(done) }
    engine.cancel()
    engine.start(code: "while(true){}", arguments: Data("{}".utf8)) { probe.complete($0) }
    let deadline = ContinuousClock.now + .seconds(1)
    while probe.reply == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(probe.reply?.code == "script_interrupted")
    #expect(!probe.waiting)
  }

  @Test func sdkPreservesTheNativeOperationDiagnosticOnTheCaughtError() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bootstrap = try String(contentsOf: root.appendingPathComponent("Sources/NotebookScriptWorker/Resources/notebook-sdk.js"), encoding: .utf8)
    let expected = Data(#"{"code":"target_missing","message":"Owner absent","operation":{"index":1,"kind":"removeElement","target":{"kind":"board","id":"158bf67a-2f9d-4b01-86cc-afc94f21f7bd"},"id":"absent"}}"#.utf8)
    let engine = NotebookQuickJSEngine(bootstrap: bootstrap) { _, _, done in
      done(.init(value: expected, code: "target_missing", message: "Owner absent"))
    }
    let result: NotebookWorkerReply = await withCheckedContinuation { continuation in
      engine.start(code: "try { await nb.transaction('atomic',{}); } catch(e) { return {code:e.code,message:e.message,operation:e.operation}; }", arguments: Data("{}".utf8)) { continuation.resume(returning: $0) }
    }
    #expect(result.code == nil)
    let actual = try JSONSerialization.jsonObject(with: #require(result.value)) as? NSDictionary
    #expect(actual == (try JSONSerialization.jsonObject(with: expected) as? NSDictionary))
  }
}
