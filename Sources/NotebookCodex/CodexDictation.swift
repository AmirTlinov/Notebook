import Foundation
import NotebookCore

/// The same transcription endpoint and App Server authorization operation used
/// by the installed Codex desktop. No credential files, separate key, or turn.
extension CodexAppServer {
  public func transcribeDictation(_ audio: Data) async throws -> String {
    try await session { rpc in
      let initial = try CodexDictationAuthorization(await rpc.request("getAuthStatus", params: .object([
        "includeToken": .bool(true), "refreshToken": .bool(false)])))
      let http = CodexDictationHTTP()
      defer { http.close() }
      do { return try await http.transcribe(audio, authorization: initial) }
      catch CodexDictationError.expiredAuthorization {
        let refreshed = try CodexDictationAuthorization(await rpc.request("getAuthStatus", params: .object([
          "includeToken": .bool(true), "refreshToken": .bool(true)])))
        guard initial.principal == refreshed.principal else { throw CodexDictationError.accountChanged }
        return try await http.transcribe(audio, authorization: refreshed)
      }
    }
  }
}

struct CodexDictationAuthorization: Sendable {
  let token: String
  let principal: String
  init(_ value: JSONValue) throws {
    guard value["authMethod"]?.string == "chatgpt", let token = value["authToken"]?.string,
      !token.isEmpty, !token.contains("\r"), !token.contains("\n") else { throw CodexDictationError.signInRequired }
    let parts = token.split(separator: ".")
    guard parts.count == 3 else { throw CodexDictationError.signInRequired }
    var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let bytes = Data(base64Encoded: encoded), let claims = try? JSONDecoder().decode(JSONValue.self, from: bytes),
      let account = claims["https://api.openai.com/auth"]?["chatgpt_account_id"]?.string,
      let subject = claims["sub"]?.string else { throw CodexDictationError.signInRequired }
    self.token = token; principal = account + "\0" + subject
  }
}

enum CodexDictationError: Error, LocalizedError {
  case signInRequired, expiredAuthorization, accountChanged, forbidden, rateLimited, unavailable, invalidAudio, invalidResponse, noSpeech
  var errorDescription: String? {
    switch self {
    case .signInRequired, .expiredAuthorization: "Войдите в Codex на Mac и повторите распознавание. Запись сохранена."
    case .accountChanged: "Учётная запись Codex изменилась. Запись сохранена; повторите распознавание с нужной учётной записью."
    case .forbidden: "Codex отказал в доступе к диктовке. Запись сохранена."
    case .rateLimited: "Достигнут лимит диктовки Codex. Повторите позже; запись сохранена."
    case .unavailable: "Сервис диктовки Codex не ответил. Запись сохранена; можно повторить распознавание."
    case .invalidAudio: "Запись не удалось прочитать или она слишком длинная."
    case .invalidResponse: "Codex вернул неполный результат диктовки. Запись сохранена."
    case .noSpeech: "Codex не распознал речь. Запись сохранена; можно повторить."
    }
  }
}

final class CodexDictationHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private var session: URLSession!
  init(configuration: URLSessionConfiguration = .ephemeral) {
    super.init()
    configuration.urlCache = nil; configuration.httpCookieStorage = nil
    configuration.timeoutIntervalForRequest = 90; configuration.timeoutIntervalForResource = 120
    configuration.httpShouldSetCookies = false
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }
  func close() { session.invalidateAndCancel() }
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }

  func transcribe(_ audio: Data, authorization: CodexDictationAuthorization) async throws -> String {
    guard !audio.isEmpty, audio.count <= NotebookDictationRecording.maximumBytes else { throw CodexDictationError.invalidAudio }
    let boundary = "NotebookDictation-" + UUID().uuidString
    var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8)
    body.append(audio); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/transcribe")!)
    request.httpMethod = "POST"; request.httpBody = body
    request.setValue("Bearer " + authorization.token, forHTTPHeaderField: "Authorization")
    request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
    request.setValue("notebook", forHTTPHeaderField: "Originator")
    let bytes: Data, response: URLResponse
    do { (bytes, response) = try await session.data(for: request) }
    catch { if Task.isCancelled { throw CancellationError() }; throw CodexDictationError.unavailable }
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse else { throw CodexDictationError.invalidResponse }
    switch http.statusCode {
    case 200: break
    case 401: throw CodexDictationError.expiredAuthorization
    case 403: throw CodexDictationError.forbidden
    case 429: throw CodexDictationError.rateLimited
    case 400, 413, 415: throw CodexDictationError.invalidAudio
    default: throw CodexDictationError.unavailable
    }
    guard bytes.count <= 256 * 1024, let value = try? JSONDecoder().decode(JSONValue.self, from: bytes),
      let text = value["text"]?.string, text.utf8.count <= 32_768 else { throw CodexDictationError.invalidResponse }
    let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !result.isEmpty else { throw CodexDictationError.noSpeech }
    return result
  }
}
