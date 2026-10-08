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

  @Test func processActivityKeepsItsWorkspaceThroughOutputDrainAndUsesOneGlobalCap() async throws {
    // Exercise the actual actor admission boundary without starting an executor.
    let server = CodexAppServer(installation: .init(binary: URL(fileURLWithPath: "/unused-codex"),
      node: URL(fileURLWithPath: "/unused-node")))
    let first = UUID(), second = UUID(), unrelated = UUID(), heldID = UUID(), gate = OutputGate()
    let held = try await server.admitProcess(id: heldID, workspaceID: first) { try await gate.publish($0) }
    var others: [CodexProcessOutput] = []
    for workspace in [first, second, second] {
      others.append(try await server.admitProcess(id: UUID(), workspaceID: workspace, publish: { _ in }))
    }
    #expect(await server.activeProcessCount(workspace: first) == 2)
    #expect(await server.activeProcessCount(workspace: second) == 2)
    #expect(await server.hasActiveWork(workspace: first))
    #expect(!(await server.hasActiveWork(workspace: unrelated)))
    await server.invalidateAccountPresentation()
    #expect(await server.activeProcessCount(workspace: first) == 2)
    await held.append(Data([120]))
    await gate.waitUntilHeld()
    await held.finish(.exited(0))
    #expect(await server.activeProcessCount(workspace: first) == 2)
    do {
      _ = try await server.admitProcess(id: UUID(), workspaceID: unrelated, publish: { _ in })
      Issue.record("A fifth workspace process bypassed the global cap")
    } catch { #expect(error as? CodexBridgeError == .busy) }
    do {
      _ = try await server.admitProcess(id: heldID, workspaceID: unrelated, publish: { _ in })
      Issue.record("An existing process changed its admitted workspace")
    } catch { #expect(error as? CodexBridgeError == .busy) }
    await gate.release(); await held.waitForDrain()
    #expect(await server.activeProcessCount(workspace: first) == 1)
    let admitted = try await server.admitProcess(id: UUID(), workspaceID: unrelated, publish: { _ in })
    #expect(await server.activeProcessCount(workspace: unrelated) == 1)
    for output in others + [admitted] { await output.finish(.exited(0)); await output.waitForDrain() }
    #expect(!(await server.hasActiveWork()))
    await server.close()
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
    let largeText = String(repeating: "x", count: CodexProtocol.frameLimit - 64)
    let large = try CodexFrames.encode(.object(["text": .string(largeText)]))
    #expect(large.count > CodexProtocol.frameLimit - 64)
    var fragmented = CodexFrames(), offset = 0, prematureFrames = 0
    // Match the physical reader's chunks, leaving the delimiter for the next
    // read together with a new partial Unicode frame.
    while offset < large.count - 1 {
      let end = min(offset + 16_384, large.count - 1)
      prematureFrames += try fragmented.append(Data(large[offset..<end])).count
      offset = end
    }
    #expect(prematureFrames == 0); #expect(fragmented.buffer.count == large.count - 1)
    let unicodePrefix = Data(bytes.dropLast())
    let completed = try fragmented.append(Data([10]) + unicodePrefix)
    #expect(completed.count == 1); #expect(completed.first?["text"] == .string(largeText))
    #expect(fragmented.buffer == unicodePrefix); #expect(fragmented.partialSince != nil)
    #expect(try fragmented.append(Data([10]) + bytes) == [value, value])
    #expect(fragmented.buffer.isEmpty); #expect(fragmented.partialSince == nil)
    var decoder = CodexFrames()
    #expect(throws: CodexBridgeError.invalidFrame) { try decoder.append(Data(repeating: 32, count: CodexProtocol.frameLimit + 1)) }
  }
  @Test(arguments: ["[]\n", "NaN\n", "{\"a\":Infinity}\n", "\n", "{bad}\n"])
  func rejectsMalformedJSON(_ input: String) {
    var decoder = CodexFrames()
    #expect(throws: CodexBridgeError.invalidFrame) { try decoder.append(Data(input.utf8)) }
  }

  @Test func structuralAdmissionRejectsSmallExpensiveFramesAndKeepsLargeTextLegal() throws {
    let deep = "{\"value\":" + String(repeating:"[",count:257) + "0" + String(repeating:"]",count:257) + "}\n"
    let crowded = "{\"tokens\":[" + String(repeating:"0,",count:270_000) + "0]}\n"
    for input in [deep, crowded] {
      let data = Data(input.utf8)
      #expect(data.count < CodexProtocol.frameLimit)
      var decoder = CodexFrames()
      #expect(throws: CodexBridgeError.invalidFrame) { try decoder.append(data) }
    }
    let text = String(repeating:"Привет🙂",count:300_000)
    let frame = try CodexFrames.encode(.object(["text":.string(text)]))
    #expect(frame.count > 4 * 1_048_576)
    var decoder = CodexFrames()
    let values = try decoder.append(frame)
    #expect(values.count == 1); #expect(values.first?["text"] == .string(text))
    #expect(decoder.buffer.isEmpty)
  }

  @Test func staleFailedJoinCannotReleaseItsSameObservationSuccessor() async throws {
    let server = CodexAppServer(installation: .init(binary: URL(fileURLWithPath: "/unused-codex"),
      node: URL(fileURLWithPath: "/unused-node")))
    let thread = "00000000-0000-0000-0000-000000000001", observation = UUID(), gate = AttachmentGate()
    let epoch = try await server.captureConversationRead(threadID: thread).connection
    let memory = server.conversationMemory, preparation = try memory.reservePreparation()
    let worker = Task<Void, Error> {
      defer { memory.releasePreparation(preparation) }
      try await gate.wait()
    }
    let entry = CodexAppServer.Attachment(id: UUID(), task: worker)
    let claim = await server.selectObservation(threadID: thread, observationID: observation)
    let old = Task { try await server.joinAttachment(threadID: thread, observationID: observation,
      claim: claim, epoch: epoch, entry: entry) }
    do {
      try await waitForAttachment(gate)
      let successor = await server.selectObservation(threadID: thread, observationID: observation)
      try await publishReadyConversation(server, thread: thread)
      try await server.joinAttachment(threadID: thread, observationID: observation, claim: successor, epoch: epoch,
        entry: .init(id: UUID(), task: Task<Void, Error> { }))
      #expect(memory.usage.preparations == 1, "The old worker still owns its physical preparation")
      await gate.release(.disconnected)
      do { try await old.value; Issue.record("The failed old join unexpectedly succeeded") }
      catch { #expect(error as? CodexBridgeError == .disconnected) }
      #expect(memory.usage.preparations == 0)
      try await expectObservationPinsConversation(server, thread: thread)
    } catch {
      await gate.release(.disconnected); _ = try? await old.value
      await server.close(); throw error
    }
    await server.close()
  }

  @Test func cancelledJoinCannotReleaseTheSameObservationFromItsSharedLoad() async throws {
    let server = CodexAppServer(installation: .init(binary: URL(fileURLWithPath: "/unused-codex"),
      node: URL(fileURLWithPath: "/unused-node")))
    let thread = "00000000-0000-0000-0000-000000000001", observation = UUID(), gate = AttachmentGate()
    let epoch = try await server.captureConversationRead(threadID: thread).connection
    let memory = server.conversationMemory, preparation = try memory.reservePreparation()
    let worker = Task<Void, Error> {
      defer { memory.releasePreparation(preparation) }
      try await gate.wait()
    }
    let entry = CodexAppServer.Attachment(id: UUID(), task: worker)
    let firstClaim = await server.selectObservation(threadID: thread, observationID: observation)
    let first = Task { try await server.joinAttachment(threadID: thread, observationID: observation,
      claim: firstClaim, epoch: epoch, entry: entry) }
    do { try await waitForAttachment(gate) }
    catch {
      await gate.release(.disconnected); _ = try? await first.value
      await server.close(); throw error
    }
    let secondClaim = await server.selectObservation(threadID: thread, observationID: observation)
    let second = Task { try await server.joinAttachment(threadID: thread, observationID: observation,
      claim: secondClaim, epoch: epoch, entry: entry) }
    do {
      first.cancel()
      #expect(!worker.isCancelled, "Cancelling one subscriber cannot cancel the shared physical load")
      #expect(memory.usage.preparations == 1)
      try await publishReadyConversation(server, thread: thread)
      await gate.release()
      try await second.value
      do { try await first.value; Issue.record("The cancelled subscriber unexpectedly succeeded") }
      catch { #expect(error is CancellationError) }
      #expect(memory.usage.preparations == 0)
      try await expectObservationPinsConversation(server, thread: thread)
    } catch {
      await gate.release(.disconnected); _ = try? await first.value; _ = try? await second.value
      await server.close(); throw error
    }
    await server.close()
  }

  private func waitForAttachment(_ gate: AttachmentGate) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await gate.entered), .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    guard await gate.entered else { throw CodexBridgeError.timeout }
  }

  private func publishReadyConversation(_ server: CodexAppServer, thread: String) async throws {
    var state = CodexAppServerState(threadID: thread)
    try state.hydrate(thread: .object(["id": .string(thread)]), history: [], turns: [])
    await server.publishConversation(state)
  }

  private func expectObservationPinsConversation(_ server: CodexAppServer, thread: String) async throws {
    let current = await server.snapshot(threadID: thread)
    #expect(current?.ready == true)
    for index in 2...9 {
      await server.publishConversation(CodexAppServerState(threadID: String(format: "00000000-0000-0000-0000-%012d", index)))
    }
    let next = UUID().uuidString, reservation = try await server.reserveLoad(threadID: next)
    // This selected thread sorts first. If a stale catch dropped its observation,
    // actual load admission would choose it as the idle victim.
    #expect(reservation.victim != nil); #expect(reservation.victim != thread)
    await server.releaseLoad(threadID: next, reservation: reservation)
  }

  @Test func concurrentHydrationsReserveDistinctVictimsBeforeAnyNativeAwait() async throws {
    let server = CodexAppServer(installation:.init(binary:URL(fileURLWithPath:"/unused-codex"),node:URL(fileURLWithPath:"/unused-node")))
    for _ in 0..<9 { await server.publishConversation(CodexAppServerState(threadID:UUID().uuidString)) }
    let a = UUID().uuidString, b = UUID().uuidString, c = UUID().uuidString
    let first = try await server.reserveLoad(threadID:a)
    let second = try await server.reserveLoad(threadID:b)
    #expect(first.victim != nil); #expect(second.victim != nil); #expect(first.victim != second.victim)
    do { _ = try await server.reserveLoad(threadID:c); Issue.record("A third hydration spent an in-flight preparation credit") }
    catch { #expect(error as? CodexBridgeError == .busy) }
    await server.releaseLoad(threadID:a,reservation:first)
    let next = try await server.reserveLoad(threadID:c)
    #expect(next.victim != second.victim)
    await server.releaseLoad(threadID:b,reservation:second)
    await server.releaseLoad(threadID:c,reservation:next)
    let memory = server.conversationMemory
    #expect(memory.usage.preparations == 0)
    await server.close()
  }

  @Test func immutableTransfersHoldActualCreditsThroughAccountAndCloseUntilTheirLastBorrower() async throws {
    let server = CodexAppServer(installation:.init(binary:URL(fileURLWithPath:"/unused-codex"),node:URL(fileURLWithPath:"/unused-node")))
    let memory = server.conversationMemory
    let thread = UUID().uuidString, workspace = UUID()
    try await server.bindWorkspace(workspace,threadID:thread)
    var state = CodexAppServerState(threadID:thread)
    let body = CodexMessage(id:"body",turnID:"turn",clientID:nil,role:.assistant,
      text:String(repeating:"x",count:7 * 1_048_576)).identifyingContent()
    try state.hydrate(thread:.object(["id":.string(thread)]),history:[body],turns:[])
    await server.publishConversation(state)
    func transfer(_ peer: UUID) async throws -> CodexMessageTransfer {
      let reply = try await server.prepareMessage(.init(threadID:thread,turnID:"turn",messageID:"body"),peer:peer)
      guard case .transfer(let value) = reply else { throw CodexBridgeError.invalidResponse }; return value
    }
    var first: CodexMessageTransfer? = try await transfer(UUID())
    var second: CodexMessageTransfer? = try await transfer(UUID())
    let before = memory.usage
    #expect(before.transfers == 2); #expect(before.transferBytes > 14 * 1_048_576)
    do { _ = try await transfer(UUID()); Issue.record("A third full transfer exceeded the global retained byte policy") }
    catch { #expect(error as? CodexBridgeError == .busy) }
    #expect(first != nil); #expect(second != nil)
    try await first!.requireCurrentOwner()
    #expect(await server.acceptAccountFrame(.object(["method":.string("account/updated"),"params":.object([:])])))
    await #expect(throws: CodexBridgeError.disconnected) { try await first!.requireCurrentOwner() }
    await server.close()
    withExtendedLifetime((first,second)) { #expect(memory.usage.transfers == 2) }
    // A caller's borrowed immutable value outlives table/account cleanup.
    var borrower = first; first = nil; second = nil
    #expect(memory.usage.transfers == 1)
    #expect(try borrower!.part(offset:0).data.count == CodexMessageTransfer.partBytes)
    borrower = nil
    #expect(memory.usage.transfers == 0)
  }

  @Test func singleItemHistoryPreservesBothEdgesExactBodiesAndReadCut() async throws {
    let fixture = try RPCFixture("""
      for n in range(4):
        q=read(); p=q['params']
        assert q['method']=='thread/items/list' and p['limit']==1
        assert p['threadId']=='thread' and p.get('turnId')=='turn'
        if n==0: assert p['sortDirection']=='desc' and 'cursor' not in p
        elif n==1: assert p['sortDirection']=='desc' and p['cursor']=='older'
        elif n==2: assert p['sortDirection']=='asc' and p['cursor']=='newer'
        else: assert p['sortDirection']=='desc' and p['cursor']=='newer'
        reply(q,{'data':[{'turnId':'turn','item':{'id':'item'+str(n),'type':'agentMessage','text':('x'*5000000 if n==0 else 'native '+str(n))}}], 'nextCursor':('older' if n==0 else ('newer' if n==3 else None)), 'backwardsCursor':(None if n in (0,3) else 'newer')})
      sys.stdin.read()
      """)
    defer { fixture.remove() }
    let rpc = CodexRPC(channel:fixture.channel); try await rpc.start()
    let cut = CodexAppServer.ConversationReadCut(connection:UUID(),account:UUID(),workspace:UUID(),thread:"thread")
    let first = try await CodexAppServer.readHistoryItem(rpc,threadID:"thread",cursor:nil,turnID:"turn",cut:cut)
    #expect(first.messages.first?.text.utf8.count == 5_000_000)
    #expect(first.newerCursor == nil)
    let older = try #require(first.nextCursor)
    let second = try await CodexAppServer.readHistoryItem(rpc,threadID:"thread",cursor:older,turnID:"turn",cut:cut)
    let newer = try #require(second.newerCursor)
    let third = try await CodexAppServer.readHistoryItem(rpc,threadID:"thread",cursor:newer,turnID:"turn",cut:cut)
    #expect(third.messages.first?.text == "native 2")
    let reversed = try #require(third.newerCursor)
    #expect(reversed != newer)
    // The same opaque token is valid in the opposite direction; keeping both
    // that token and its direction unchanged is genuine forward no-progress.
    await #expect(throws: CodexBridgeError.invalidResponse) {
      try await CodexAppServer.readHistoryItem(rpc,threadID:"thread",cursor:reversed,turnID:"turn",cut:cut)
    }
    let successor = CodexAppServer.ConversationReadCut(connection:cut.connection,account:UUID(),workspace:cut.workspace,thread:cut.thread)
    do { _ = try await CodexAppServer.readHistoryItem(rpc,threadID:"thread",cursor:older,turnID:"turn",cut:successor); Issue.record("An old native cursor crossed the account cut") }
    catch { #expect(error as? CodexBridgeError == .staleRequest) }
    await rpc.stop()
  }
}


private actor AttachmentGate {
  var entered = false
  private var released = false
  private var failure: CodexBridgeError?
  private var continuation: CheckedContinuation<Void, Error>?
  func wait() async throws {
    entered = true
    if released { if let failure { throw failure }; return }
    try await withCheckedThrowingContinuation { continuation = $0 }
  }
  func release(_ error: CodexBridgeError? = nil) {
    guard !released else { return }
    released = true; failure = error
    let current = continuation; continuation = nil
    if let error { current?.resume(throwing: error) } else { current?.resume() }
  }
}

private actor OutputGate {
  var bytes = 0, stops = 0
  var failure: String?
  var done = false
  private var open = false
  private var waiter: CheckedContinuation<Void, Never>?
  private var heldWaiters: [CheckedContinuation<Void, Never>] = []
  func publish(_ event: NotebookProcessEvent) async throws {
    switch event {
    case .output(let data):
      if !open {
        await withCheckedContinuation { continuation in
          waiter = continuation
          let waiters = heldWaiters; heldWaiters.removeAll()
          for waiting in waiters { waiting.resume() }
        }
      }
      bytes += data.count
    case .interrupted(let message): failure = message
    default: break
    }
  }
  func waitUntilHeld() async {
    if waiter != nil { return }
    await withCheckedContinuation { heldWaiters.append($0) }
  }
  func release() { open = true; waiter?.resume(); waiter = nil }
  func stopped() { stops += 1 }
  func completed() { done = true }
}
