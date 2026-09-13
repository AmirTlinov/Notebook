import Foundation
import Testing
import NotebookCore
@testable import NotebookCodex

@Suite("Codex dictation uses account authorization without exporting it", .serialized)
struct CodexDictationTests {
  final class Stub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
      do {
        let (status, data) = try Self.handler!(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
      } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
  }
  func authorization(account: String = "synthetic-account") throws -> CodexDictationAuthorization {
    let payload = try JSONSerialization.data(withJSONObject: ["sub": "synthetic-user", "https://api.openai.com/auth": ["chatgpt_account_id": account]])
    let encoded = payload.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    return try .init(.object(["authMethod": .string("chatgpt"), "authToken": .string("synthetic." + encoded + ".not-a-credential")]))
  }
  func client() -> CodexDictationHTTP {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [Stub.self]
    return CodexDictationHTTP(configuration: configuration)
  }
  @Test func sendsOnlyAudioToTheExactTranscriptionEndpointAndReturnsEditableText() async throws {
    let auth = try authorization()
    Stub.handler = { request in
      #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/transcribe")
      #expect(request.httpMethod == "POST")
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + auth.token)
      #expect(request.value(forHTTPHeaderField: "Originator") == "notebook")
      #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=NotebookDictation-") == true)
      return (200, Data(#"{"text":"  Русский текст. \n","asset_pointer":"ignored"}"#.utf8))
    }
    let http = client(); defer { http.close(); Stub.handler = nil }
    #expect(try await http.transcribe(Data([1, 2, 3]), authorization: auth) == "Русский текст.")
  }
  @Test func serviceRefusalsEmptyTextAndOversizedTextHaveExplicitFailures() async throws {
    let auth = try authorization()
    for (status, body) in [(401, "{}"), (403, "{}"), (429, "{}"), (200, "{}"), (200, #"{"text":"  "}"#),
      (200, "{\"text\":\"" + String(repeating: "x", count: 32_769) + "\"}")] {
      Stub.handler = { _ in (status, Data(body.utf8)) }
      let http = client()
      await #expect(throws: CodexDictationError.self) { try await http.transcribe(Data([1]), authorization: auth) }
      http.close()
    }
    Stub.handler = nil
  }
  @Test func transportErrorsCannotExposeAuthorizationOrServerPayloads() async throws {
    let auth = try authorization()
    Stub.handler = { _ in throw NSError(domain: "Secret " + auth.token, code: 1) }
    let http = client(); defer { http.close(); Stub.handler = nil }
    do { _ = try await http.transcribe(Data([1]), authorization: auth); Issue.record("Expected an unavailable service") }
    catch { #expect(!error.localizedDescription.contains(auth.token)); #expect(error.localizedDescription.contains("Запись сохранена")) }
  }
  @Test func authMustBeChatGPTAndAccountSwitchesRemainDistinguishable() throws {
    #expect(try authorization().principal != authorization(account: "other").principal)
    for value: JSONValue in [.object([:]), .object(["authMethod": .string("apiKey"), "authToken": .string("synthetic-key")]),
      .object(["authMethod": .string("chatgpt"), "authToken": .string("bad\nheader")])] {
      #expect(throws: CodexDictationError.self) { try CodexDictationAuthorization(value) }
    }
  }
}
