import Foundation
import Testing
import NotebookCore
@testable import NotebookCodex

private struct RPCFixture {
  let root: URL
  let channel: CodexChannel
  init(_ body: String, respondsToInitialize: Bool = true) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-app-server-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let file = root.appendingPathComponent("server")
    try Data(("""
      #!/usr/bin/python3
      import json,sys
      def read(): return json.loads(sys.stdin.readline())
      def write(v): print(json.dumps(v), flush=True)
      def reply(q,v): write({'id':q['id'],'result':v})
      """ + "\n" + (respondsToInitialize ? "reply(read(), {'userAgent':'test'})\nassert read()['method']=='initialized'\n" : "") + body).utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    channel = try CodexChannel.appServer(binary: file, directory: root)
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Persistent App Server transport")
struct CodexConnectionTests {
  @Test func slowOutputDoesNotDelayAnAlreadyReceivedControlReply() async throws {
    let fixture = try RPCFixture("""
      q=read()
      write({'method':'command/exec/outputDelta','params':{'deltaBase64':'eA=='}})
      reply(q,{'control':True})
      sys.stdin.read()
      """)
    defer { fixture.remove() }
    let gate = OutputGate()
    let output = CodexProcessOutput(publish: { try await gate.publish($0) }, stop: {}, completed: {})
    let rpc = CodexRPC(channel: fixture.channel)
    try await rpc.start(onEvent: { frame in
      if frame["method"] == .string("command/exec/outputDelta") { await output.append(Data([120])) }
    })
    let start = ContinuousClock.now
    #expect(try await rpc.request("account/read", params: .object([:]), timeout: .milliseconds(500))["control"] == .bool(true))
    print("CONTROL_REPLY_WITH_HELD_OUTPUT", start.duration(to: .now))
    await output.finish(.exited(0)); await gate.release()
    await rpc.stop()
  }

  @Test func outputBudgetIncludesInFlightBytesAndReportsTheUnwrittenTail() async throws {
    let gate = OutputGate()
    let output = CodexProcessOutput(publish: { try await gate.publish($0) },
      stop: { await gate.stopped() }, completed: { await gate.completed() })
    for _ in 0..<5 { await output.append(Data(repeating: 120, count: 128 * 1024)) }
    #expect(await output.queuedBytes <= CodexProcessOutput.byteLimit)
    await output.finish(.exited(0)); await gate.release()
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await gate.done), .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await gate.done); #expect(await gate.stops == 1)
    #expect(await gate.bytes == 512 * 1024)
    #expect(await gate.failure?.contains("Вывод неполный") == true)
    #expect(await output.queuedBytes == 0)
  }

  @Test func receivedRefusalKeepsItsCodeAndIsNotAnUnknownAcceptance() async throws {
    let fixture = try RPCFixture("q=read()\nwrite({'id':q['id'],'error':{'code':-32602,'message':'private request content'}})\nsys.stdin.read()\n")
    defer { fixture.remove() }
    let rpc = CodexRPC(channel: fixture.channel); try await rpc.start()
    do { _ = try await rpc.request("turn/start", params: .object([:])); Issue.record("Expected refusal") }
    catch let rejection as CodexRequestRejection { #expect(rejection.code == -32602); #expect(!rejection.localizedDescription.contains("private request content")) }
    await rpc.stop()
  }

  @Test func failedInitializationReportsOnlyItsStageAndActualExitCode() async throws {
    let fixture = try RPCFixture("read()\nprint('opaque child stderr', file=sys.stderr)\nsys.exit(17)\n", respondsToInitialize: false)
    defer { fixture.remove() }
    let rpc = CodexRPC(channel: fixture.channel)
    await #expect(throws: CodexStartupFailure(exitCode: 17)) { try await rpc.start() }
    await rpc.stop()
  }

  @Test func nonzeroExitOfEstablishedChannelRemainsDisconnected() async throws {
    let fixture = try RPCFixture("read()\nsys.exit(17)\n")
    defer { fixture.remove() }
    let rpc = CodexRPC(channel: fixture.channel); try await rpc.start()
    await #expect(throws: CodexBridgeError.disconnected) { try await rpc.request("thread/read", params: .object([:])) }
    await rpc.stop()
  }

  @Test func explicitStopWhileInitializingIsNotAStartupFailure() async throws {
    let fixture = try RPCFixture("import os\nread()\nopen(os.path.join(os.path.dirname(__file__),'initializing'),'w').close()\nassert sys.stdin.read()==''\n", respondsToInitialize: false)
    defer { fixture.remove() }
    let rpc = CodexRPC(channel: fixture.channel)
    let start = Task { try await rpc.start() }
    try await waitForInitialization(fixture)
    await rpc.stop()
    await #expect(throws: CodexBridgeError.disconnected) { try await start.value }
  }

  @Test func cancellingInitializationIsNotAStartupFailure() async throws {
    let fixture = try RPCFixture("import os\nread()\nopen(os.path.join(os.path.dirname(__file__),'initializing'),'w').close()\nassert sys.stdin.read()==''\n", respondsToInitialize: false)
    defer { fixture.remove() }
    let rpc = CodexRPC(channel: fixture.channel)
    let start = Task { try await rpc.start() }
    try await waitForInitialization(fixture)
    start.cancel()
    await #expect(throws: CodexBridgeError.disconnected) { try await start.value }
    await rpc.stop()
  }

  private func waitForInitialization(_ fixture: RPCFixture) async throws {
    let marker = fixture.root.appendingPathComponent("initializing").path
    let deadline = ContinuousClock.now + .seconds(3)
    while !FileManager.default.fileExists(atPath: marker), .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(FileManager.default.fileExists(atPath: marker))
  }

  @Test func requestsAndNativeQuestionsShareOneConnectionWithoutLosingNumericIDs() async throws {
    let fixture = try RPCFixture("""
      q=read()
      write({'id':276,'method':'item/permissions/requestApproval','params':{'threadId':'thread','turnId':'turn','permissions':{}}})
      r=read()
      assert r=={'id':276,'result':{'permissions':{},'scope':'turn'}}
      reply(q,{'received':True})
      q=read(); reply(q,{'again':True})
      sys.stdin.read()
      """)
    defer { fixture.remove() }
    let rpc = CodexRPC(channel: fixture.channel)
    try await rpc.start(onEvent: { frame in
      // A response write does not wait for another read. No nested RPC in the serial reader.
      try await rpc.respond(id: frame["id"]!, result: .object(["permissions": .object([:]), "scope": .string("turn")]))
    })
    #expect(try await rpc.request("thread/read", params: .object([:]))["received"] == .bool(true))
    #expect(try await rpc.request("thread/read", params: .object([:]))["again"] == .bool(true))
    await rpc.stop()
  }
  @Test func foreignWriterRefusalIsNotRetriedOrTakenOver() async throws {
    let fixture = try RPCFixture("""
      q=read(); assert q['method']=='thread/resume'
      write({'id':q['id'],'error':{'code':-32600,'message':'thread already has an active writer'}})
      assert sys.stdin.read()==''
      """)
    defer { fixture.remove() }
    let rpc = CodexRPC(channel: fixture.channel); try await rpc.start()
    await #expect(throws: CodexBridgeError.externalOwnerUnavailable) {
      try await rpc.request("thread/resume", params: .object(["threadId": .string("thread")]))
    }
    await rpc.stop()
  }
  @Test func disconnectCompletesOutstandingMutationWithoutRetry() async throws {
    let fixture = try RPCFixture("q=read(); assert q['method']=='turn/start'\n")
    defer { fixture.remove() }
    let rpc = CodexRPC(channel: fixture.channel); try await rpc.start()
    await #expect(throws: CodexBridgeError.disconnected) { try await rpc.request("turn/start", params: .object([:])) }
    await rpc.stop()
  }
  @Test func slowStartupRetainsItsReplyBeyondTheReadDeadlineWhileOtherRequestsContinue() async throws {
    let fixture = try RPCFixture("""
      import time,os
      start=read(); assert start['method']=='thread/start'
      open(os.path.join(os.path.dirname(__file__),'started'),'w').close()
      q=read(); assert q['method']=='account/read'; reply(q,{'available':True})
      time.sleep(13)
      reply(start,{'thread':{'id':'a2635f14-064e-4dc1-87ea-2a47ac04e4df'}})
      assert sys.stdin.read()==''
      """)
    defer { fixture.remove() }
    let rpc = CodexRPC(channel: fixture.channel); try await rpc.start()
    let start = Task { try await rpc.request("thread/start", params: .object([:]), timeout: nil) }
    let deadline = ContinuousClock.now + .seconds(3)
    while !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("started").path), .now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await rpc.request("account/read", params: .object([:]))["available"] == .bool(true))
    #expect(try await start.value["thread"]?["id"]?.string == "a2635f14-064e-4dc1-87ea-2a47ac04e4df")
    await rpc.stop()
  }
  @Test func cancellingUntimedStartupReleasesTheCallerWithoutRepeatingTheMutation() async throws {
    let fixture = try RPCFixture("q=read(); assert q['method']=='thread/start'\nassert sys.stdin.read()==''\n")
    defer { fixture.remove() }
    let rpc = CodexRPC(channel: fixture.channel); try await rpc.start()
    let start = Task { try await rpc.request("thread/start", params: .object([:]), timeout: nil) }
    try await Task.sleep(for: .milliseconds(100))
    start.cancel()
    await #expect(throws: CodexBridgeError.disconnected) { try await start.value }
    await rpc.stop()
  }
  @Test func fragmentedFramesRetainUnicodeAndBoundTheirSize() throws {
    let value: JSONValue = .object(["text": .string("∫ x² dx 👨‍👩‍👧‍👦")])
    let bytes = try CodexFrames.encode(value)
    for split in 0...bytes.count {
      var decoder = CodexFrames()
      #expect(try decoder.append(Data(bytes.prefix(split))) + decoder.append(Data(bytes.dropFirst(split))) == [value])
      #expect(decoder.buffer.isEmpty); #expect(decoder.partialSince == nil)
    }
    var decoder = CodexFrames()
    #expect(throws: CodexBridgeError.invalidFrame) { try decoder.append(Data(repeating: 32, count: CodexProtocol.frameLimit + 1)) }
  }
  @Test(arguments: ["[]\n", "NaN\n", "{\"a\":Infinity}\n", "\n", "{bad}\n"])
  func rejectsMalformedJSON(_ input: String) {
    var decoder = CodexFrames()
    #expect(throws: CodexBridgeError.invalidFrame) { try decoder.append(Data(input.utf8)) }
  }
}


private actor OutputGate {
  var bytes = 0, stops = 0
  var failure: String?
  var done = false
  private var open = false
  private var waiter: CheckedContinuation<Void, Never>?
  func publish(_ event: NotebookProcessEvent) async throws {
    switch event {
    case .output(let data):
      if !open { await withCheckedContinuation { waiter = $0 } }
      bytes += data.count
    case .interrupted(let message): failure = message
    default: break
    }
  }
  func release() { open = true; waiter?.resume(); waiter = nil }
  func stopped() { stops += 1 }
  func completed() { done = true }
}
