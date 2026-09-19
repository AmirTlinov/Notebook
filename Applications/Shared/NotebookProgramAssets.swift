import Foundation
import NotebookCore
import WebKit

/// A capability local to one existing WebKit owner. The browser supplies a
/// relative path, never a store path or SHA. Revoking a load cancels its readers
/// and denies every later callback, including an already running SQLite read.
@MainActor
final class NotebookProgramAssets: NSObject, WKURLSchemeHandler {
  static let scheme = "notebook-program"
  struct Document { let before: String; let after: String }
  private enum Segment: Sendable {
    case bytes(Data), file(NotebookProgramPackage.File)
    var count: Int64 { switch self { case .bytes(let data): Int64(data.count); case .file(let file): file.byteCount } }
  }
  private struct Scope: Sendable {
    let store: NotebookStore
    let files: [String: NotebookProgramPackage.File]
    let document: [Segment]
    func read(_ segments: [Segment], offset: Int64, count: Int) throws -> Data {
      var position: Int64 = 0, output = Data()
      let end = offset + Int64(count)
      for segment in segments {
        let upper = position + segment.count
        defer { position = upper }
        guard offset < upper, end > position else { continue }
        let start = max(offset, position) - position, finish = min(end, upper) - position
        switch segment {
        case .bytes(let data): output.append(data.subdata(in: Int(start)..<Int(finish)))
        case .file(let file): output.append(try store.readProgramFile(file, offset: start, maxBytes: Int(finish - start)))
        }
      }
      guard output.count == count else { throw NotebookStorageError.blobHashMismatch }
      return output
    }
  }
  private struct Read { let host: String; let task: Task<Void, Never> }
  private var scopes: [String: Scope] = [:]
  private var reads: [ObjectIdentifier: Read] = [:]
  var activeReadCount: Int { reads.count }
  var scopeCount: Int { scopes.count }

  func register(store: NotebookStore, package: NotebookProgramPackage, document: (URL) throws -> Document) rethrows -> URL {
    let host = UUID().uuidString.lowercased(), url = URL(string: "\(Self.scheme)://\(host)/")!
    let wrapper = try document(url)
    var segments: [Segment] = [.bytes(Data(wrapper.before.utf8))]
    if let path = package.html, let file = package.files.first(where: { $0.path == path }) { segments.append(.file(file)) }
    segments.append(.bytes(Data(wrapper.after.utf8)))
    scopes[host] = Scope(store: store, files: Dictionary(uniqueKeysWithValues: package.files.map { ($0.path, $0) }), document: segments)
    return url
  }

  func revoke(_ url: URL) { if let host = url.host { revoke(host: host) } }
  private func revoke(host: String) {
    scopes[host] = nil
    for (id, read) in reads where read.host == host { reads[id] = nil; read.task.cancel() }
  }
  func revokeAll() { for host in scopes.keys { revoke(host: host) } }

  static func policy(origin: URL) -> String {
    let source = origin.absoluteString
    return "default-src 'none'; img-src data: blob: \(source); style-src 'unsafe-inline' \(source); script-src 'unsafe-inline' 'wasm-unsafe-eval' \(source); connect-src \(source); font-src data: \(source); media-src data: blob: \(source); worker-src blob: \(source); frame-src 'none'; form-action 'none'; base-uri 'none'; object-src 'none'"
  }
  static func style(_ package: NotebookProgramPackage, origin: URL) -> String {
    package.css.map { "<link rel=\"stylesheet\" href=\"\(origin.absoluteString)\($0)\">" } ?? ""
  }
  static func script(_ package: NotebookProgramPackage, origin: URL) -> String {
    package.javaScript.map { "<script\(package.module ? " type=\"module\"" : "") src=\"\(origin.absoluteString)\($0)\"></script>" } ?? ""
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    let request = urlSchemeTask.request, id = ObjectIdentifier(urlSchemeTask)
    guard reads.count < 64, let url = request.url, url.scheme == Self.scheme, let host = url.host,
      let scope = scopes[host], let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.user == nil, components.password == nil, components.port == nil, components.query == nil,
      components.fragment == nil, !components.percentEncodedPath.contains("%"),
      ["GET", "HEAD"].contains(request.httpMethod ?? "GET") else {
      urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile)); return
    }
    let path = String(components.percentEncodedPath.dropFirst()), segments: [Segment], mime: String
    if path.isEmpty { segments = scope.document; mime = "text/html" }
    else if NotebookProgramPackage.validPath(path), let file = scope.files[path] { segments = [.file(file)]; mime = file.mimeType }
    else { urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return }
    let size = segments.reduce(Int64(0)) { $0 + $1.count }
    let rangeHeader = request.value(forHTTPHeaderField: "Range")
    guard let range = Self.range(rangeHeader, length: size) else {
      urlSchemeTask.didReceive(HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields:
        ["Content-Range": "bytes */\(size)", "Content-Length": "0", "Access-Control-Allow-Origin": "*"])!)
      urlSchemeTask.didFinish(); return
    }
    var headers = ["Content-Type": mime, "Content-Length": String(range.count), "Accept-Ranges": "bytes",
      "Access-Control-Allow-Origin": "*", "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store",
      "Content-Security-Policy": Self.policy(origin: URL(string: "\(Self.scheme)://\(host)/")!)]
    if rangeHeader != nil { headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(size)" }
    let response = HTTPURLResponse(url: url, statusCode: rangeHeader == nil ? 200 : 206, httpVersion: "HTTP/1.1", headerFields: headers)!
    let task = Task { @MainActor [weak self] in
      guard let self, reads[id] != nil else { return }
      do {
        urlSchemeTask.didReceive(response)
        var offset = range.lowerBound
        while request.httpMethod != "HEAD", offset < range.upperBound {
          try Task.checkCancellation()
          let count = Int(min(1_048_576, range.upperBound - offset)), position = offset
          let data = try await Task.detached(priority: .userInitiated) { try scope.read(segments, offset: position, count: count) }.value
          guard !Task.isCancelled, reads[id] != nil, scopes[host] != nil else { return }
          urlSchemeTask.didReceive(data); offset += Int64(data.count)
        }
        guard !Task.isCancelled, reads[id] != nil else { return }
        reads[id] = nil; urlSchemeTask.didFinish()
      } catch {
        guard !Task.isCancelled, reads[id] != nil else { return }
        reads[id] = nil; urlSchemeTask.didFailWithError(error)
      }
    }
    reads[id] = .init(host: host, task: task)
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
    reads.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.task.cancel()
  }

  static func range(_ header: String?, length: Int64) -> Range<Int64>? {
    guard length >= 0 else { return nil }
    guard let header else { return 0..<length }
    guard length > 0, header.hasPrefix("bytes="), header.utf8.count <= 128 else { return nil }
    let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2, parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
    if parts[0].isEmpty {
      guard let suffix = Int64(parts[1]), suffix > 0 else { return nil }
      return max(0, length - suffix)..<length
    }
    guard let start = Int64(parts[0]), start < length else { return nil }
    if parts[1].isEmpty { return start..<length }
    guard let last = Int64(parts[1]), last >= start else { return nil }
    return start..<(min(last, length - 1) + 1)
  }
}
