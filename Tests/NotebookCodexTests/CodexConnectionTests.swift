import Foundation
import Testing
import NotebookCore
@testable import NotebookCodex

private struct RPCFixture {
  let root: URL
  let channel: CodexChannel
  init(_ body: String) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-app-server-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let file = root.appendingPathComponent("server")
    try Data(("""
      #!/usr/bin/python3
      import json,sys
      def read(): return json.loads(sys.stdin.readline())
      def write(v): print(json.dumps(v), flush=True)
      def reply(q,v): write({'id':q['id'],'result':v})
      reply(read(), {'userAgent':'test'})
      assert read()['method']=='initialized'

      """ + body).utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    channel = try CodexChannel.appServer(binary: file, directory: root)
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Persistent App Server transport")
struct CodexConnectionTests {
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
