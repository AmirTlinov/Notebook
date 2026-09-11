import Foundation
import NotebookCore
import WebKit

struct DocumentBrowserRegion: Codable, Sendable {
  let id: String
  let pageIndex: Int
  let x: Double
  let y: Double
  let width: Double
  let height: Double
  let sourceOffset: Double
}

struct DocumentBrowserDiagnostic: Codable, Sendable {
  let kind: String
  let message: String
  let blockID: String?
}

struct DocumentPageFragment: Codable, Sendable {
  let format: Int
  let sourceKey: String
  let pageIndex: Int
  let width: Double
  let height: Double
  let contentTop: Double
  let contentBottom: Double
  let blockIDs: [String]
  let regions: [DocumentBrowserRegion]
  let html: String
  let nodeCount: Int
  let utf8Bytes: Int
}

private struct DocumentPreparedLayout: Decodable {
  let sourceKey: String
  let pageCount: Int
  let diagnostics: [DocumentBrowserDiagnostic]
  let mathStyles: String
}

struct DocumentPacketDescriptor: Decodable {
  let sourceKey: String
  let pageIndex: Int?
  let utf8Bytes: Int

  static func decode(_ json: String, sourceKey: String, pageIndex: Int?, maximumBytes: Int) throws -> Self {
    guard json.utf8.count <= 512 else { throw DocumentSessionError.invalidLayout }
    let value = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    guard value.sourceKey == sourceKey, value.pageIndex == pageIndex,
      value.utf8Bytes > 0, value.utf8Bytes <= maximumBytes else { throw DocumentSessionError.invalidLayout }
    return value
  }
}

private struct DocumentPageSource: Encodable, Sendable {
  let source: DocumentSourceMessage
  let pageCount: Int
  let diagnostics: [DocumentBrowserDiagnostic]
  let mathStyles: String
  let fragment: DocumentPageFragment
}

@MainActor
final class DocumentPageMessage {
  let json: String
  private let reservation: RasterReservation
  init(json: String, reservation: RasterReservation) { self.json = json; self.reservation = reservation }
  isolated deinit { reservation.release() }
}

@MainActor
final class DocumentPreparedPage {
  let fragment: DocumentPageFragment
  private let envelope: DocumentPageSource
  private let encodingBudget: Int
  private let reservation: RasterReservation
  private let mathStyleReservation: RasterReservation
  fileprivate init(envelope: DocumentPageSource, encodingBudget: Int, reservation: RasterReservation, mathStyleReservation: RasterReservation) {
    fragment = envelope.fragment; self.envelope = envelope; self.encodingBudget = encodingBudget; self.reservation = reservation
    self.mathStyleReservation = mathStyleReservation
  }
  /// The snapshot keeps one DOM fragment, not one full source encoding per
  /// historical page. Only the physical host's current bridge message is encoded.
  func encodedMessage(resources: SceneRenderResources) async throws -> DocumentPageMessage {
    // The bound belongs to this page, not every source block in the book.
    // Twice the browser JSON bounds Swift's slash escaping.
    // Both encoder output and the submitted script stay charged until callback.
    guard encodingBudget <= 40 * 1024 * 1024,
      let reservation = resources.reserveDerivedBytes(encodingBudget * 2, priority: .passive) else { throw SceneRenderError.resourceLimit }
    do {
      let envelope = envelope
      let json = try await Task.detached(priority: .userInitiated) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(envelope), as: UTF8.self)
      }.value
      try Task.checkCancellation()
      guard json.utf8.count <= encodingBudget else { throw SceneRenderError.resourceLimit }
      return DocumentPageMessage(json: json, reservation: reservation)
    } catch { reservation.release(); throw error }
  }
  isolated deinit { reservation.release() }
}

@MainActor
final class DocumentPreparedSource {
  let layout: DocumentLayoutRecord
  let pages: [DocumentPreparedPage]
  init(layout: DocumentLayoutRecord, pages: [DocumentPreparedPage]) { self.layout = layout; self.pages = pages }
  func page(_ requested: Int) -> DocumentPreparedPage { pages[min(max(0, requested), pages.count - 1)] }
}

/// One source snapshot commissions one passive DOM measurement on an existing
/// page lease. Waiters share the result, not a WebKit or a second live program.
@MainActor
final class DocumentPagePreparation {
  private var task: Task<Void, Never>?
  private var result: Result<DocumentPreparedSource, Error>?
  private var waiters: [UUID: CheckedContinuation<DocumentPreparedSource, Error>] = [:]
  private weak var web: WKWebView?
  private let key: String
  var failed: Bool { if case .failure = result { true } else { false } }

  init(message: DocumentSourceMessage, sourceJSON: Task<String, Error>, web: WKWebView,
    lease: WebSurfaceLease, resources: SceneRenderResources) throws {
    self.web = web; key = message.key
    let borrow = try lease.borrow()
    task = Task { @MainActor [weak self] in
      defer { borrow.release() }
      let outcome: Result<DocumentPreparedSource, Error>
      do {
        let json = try await sourceJSON.value
        try Task.checkCancellation()
        outcome = .success(try await Self.prepare(message: message, json: json, in: web, resources: resources))
      } catch { outcome = .failure(error) }
      self?.complete(outcome)
    }
  }

  func value() async throws -> DocumentPreparedSource {
    try Task.checkCancellation()
    if let result { return try result.get() }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
        if let result { continuation.resume(with: result); return }
        waiters[id] = continuation
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelWaiter(id) }
    }
  }

  private func cancelWaiter(_ id: UUID) {
    waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    if waiters.isEmpty, result == nil { cancel() }
  }

  private func cancel() {
    task?.cancel()
    // The native borrow stays held until the outstanding WebKit callback,
    // including an already submitted MathJax pass, has actually returned.
    web?.callAsyncJavaScript("window.notebookRenderer.finishSourcePreparation(key); return true;",
      arguments: ["key": key], in: nil, in: .page, completionHandler: nil)
  }

  private func complete(_ result: Result<DocumentPreparedSource, Error>) {
    self.result = result; task = nil
    let pending = waiters.values; waiters.removeAll()
    for continuation in pending { continuation.resume(with: result) }
  }

  isolated deinit {
    cancel()
    for continuation in waiters.values { continuation.resume(throwing: CancellationError()) }
  }

  private static func evaluate(_ script: String, arguments: [String: Any], in web: WKWebView) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
        switch result {
        case .success(let value):
          if let string = value as? String { continuation.resume(returning: string) }
          else { continuation.resume(throwing: DocumentSessionError.invalidLayout) }
        case .failure(let error): continuation.resume(throwing: error)
        }
      }
    }
  }

  private static func prepare(message: DocumentSourceMessage, json: String, in web: WKWebView,
    resources: SceneRenderResources) async throws -> DocumentPreparedSource {
    let geometry = WorkspaceItemGeometry.document(message.paper.kind)
    let sourceBytes = json.utf8.count
    guard sourceBytes <= 16 * 1024 * 1024 else { throw SceneRenderError.resourceLimit }
    do {
      let (raw, layoutPacket) = try await readPacket(
        preparing: "return JSON.stringify(await window.notebookRenderer.beginSourcePreparation(JSON.parse(source)));",
        arguments: ["source": json], sourceKey: message.key, pageIndex: nil,
        maximumBytes: 16 * 1024 * 1024, inputBytes: sourceBytes, in: web, resources: resources)
      guard let receipt = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? NSDictionary else { throw DocumentSessionError.invalidLayout }
      let blocks = Dictionary(uniqueKeysWithValues: message.blocks.map { ($0.id, $0) }), blockIDs = Set(blocks.keys)
      // Unreferenced string bodies contribute at least their UTF-8 byte count
      // to the original JSON. Subtract only that proven lower bound: escaping,
      // metadata, state and future encoded fields remain conservatively charged.
      // No second full encoding or JSON object tree is created to measure it.
      let bodyBytes = Dictionary(uniqueKeysWithValues: message.blocks.map { block in
        (block.id, block.source.utf8.count + block.html.utf8.count
          + block.css.utf8.count + block.javaScript.utf8.count)
      })
      let allBodyBytes = bodyBytes.values.reduce(0, +)
      guard allBodyBytes <= sourceBytes else { throw DocumentSessionError.invalidLayout }
      let layout = try DocumentLayoutRecord(receipt: receipt, sourceKey: message.key, blockIDs: blockIDs,
        geometry: geometry, reservation: layoutPacket)
      let measured = try JSONDecoder().decode(DocumentPreparedLayout.self, from: JSONSerialization.data(withJSONObject: receipt))
      guard measured.sourceKey == message.key, measured.pageCount == layout.pageCount,
        (1...4096).contains(layout.pageCount) else { throw DocumentSessionError.invalidLayout }
      let diagnosticsBytes = try JSONEncoder().encode(measured.diagnostics).count
      let mathStyleBytes = measured.mathStyles.utf8.count
      guard diagnosticsBytes <= 64 * 1024, mathStyleBytes <= 128 * 1024 else { throw SceneRenderError.resourceLimit }
      guard let mathStyleReservation = resources.reserveDerivedBytes(max(1, mathStyleBytes), priority: .passive) else { throw SceneRenderError.resourceLimit }
      var pages: [DocumentPreparedPage] = []
      for pageIndex in 0..<layout.pageCount {
        try Task.checkCancellation()
        let (json, staging) = try await readPacket(
          preparing: "return JSON.stringify(window.notebookRenderer.preparePagePacket(key, index));",
          arguments: ["key": message.key, "index": pageIndex], sourceKey: message.key, pageIndex: pageIndex,
          maximumBytes: 8 * 1024 * 1024, in: web, resources: resources)
        defer { staging.release() }
        let fragment = try JSONDecoder().decode(DocumentPageFragment.self, from: Data(json.utf8))
        guard fragment.format == 1, fragment.sourceKey == message.key, fragment.pageIndex == pageIndex,
          fragment.utf8Bytes == fragment.html.utf8.count, fragment.utf8Bytes <= 4 * 1024 * 1024,
          fragment.nodeCount <= 16_384, fragment.contentTop.isFinite, fragment.contentBottom.isFinite,
          fragment.contentTop >= 0, fragment.contentBottom >= fragment.contentTop, fragment.contentBottom <= fragment.height,
          Set(fragment.blockIDs).count == fragment.blockIDs.count,
          fragment.blockIDs.allSatisfy({ blocks[$0] != nil }),
          Set(fragment.regions.map(\.id)) == Set(fragment.blockIDs) else { throw DocumentSessionError.invalidLayout }
        var fragmentReceipt = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        fragmentReceipt["layoutScope"] = "page"
        fragmentReceipt["layoutCanonical"] = true; fragmentReceipt["pageCount"] = layout.pageCount
        let physical = try DocumentLayoutRecord(receipt: fragmentReceipt as NSDictionary, sourceKey: message.key, blockIDs: blockIDs, geometry: geometry)
        guard layout.matches(physical, pageIndex: pageIndex) else { throw DocumentSessionError.inconsistentLayout }
        let source = DocumentSourceMessage(key: message.key, documentID: message.documentID, paper: message.paper,
          blocks: fragment.blockIDs.compactMap { blocks[$0] },
          sourceVersions: Dictionary(uniqueKeysWithValues: fragment.blockIDs.compactMap { id in message.sourceVersions[id].map { (id, $0) } }))
        let envelope = DocumentPageSource(source: source, pageCount: layout.pageCount,
          diagnostics: measured.diagnostics, mathStyles: measured.mathStyles, fragment: fragment)
        let retainedBytes = max(1, json.utf8.count)
        staging.release()
        guard let retained = resources.reserveDerivedBytes(retainedBytes, priority: .passive) else { throw SceneRenderError.resourceLimit }
        let pageSourceBytes = sourceBytes - allBodyBytes + fragment.blockIDs.reduce(0) { $0 + (bodyBytes[$1] ?? 0) }
        pages.append(DocumentPreparedPage(envelope: envelope, encodingBudget: pageSourceBytes + json.utf8.count * 2 + diagnosticsBytes + mathStyleBytes * 6 + 256,
          reservation: retained, mathStyleReservation: mathStyleReservation))
      }
      _ = try await evaluate("window.notebookRenderer.finishSourcePreparation(key); return 'finished';", arguments: ["key": message.key], in: web)
      return DocumentPreparedSource(layout: layout, pages: pages)
    } catch {
      _ = try? await evaluate("window.notebookRenderer.finishSourcePreparation(key); return 'finished';", arguments: ["key": message.key], in: web)
      throw error
    }
  }

  /// The browser first freezes one bounded packet and announces its byte count.
  /// Admission precedes transfer; the same source/page and exact UTF-8 length
  /// must come back. No maximum-size buffer occupies the pool between pages.
  private static func readPacket(preparing script: String, arguments: [String: Any],
    sourceKey: String, pageIndex: Int?, maximumBytes: Int, inputBytes: Int = 0,
    in web: WKWebView, resources: SceneRenderResources) async throws -> (String, RasterReservation) {
    guard let announcement = resources.reserveDerivedBytes(512 * 3 + inputBytes * 2, priority: .passive) else {
      throw SceneRenderError.resourceLimit
    }
    defer { announcement.release() }
    let raw = try await evaluate(script, arguments: arguments, in: web)
    try Task.checkCancellation()
    let descriptor = try DocumentPacketDescriptor.decode(raw, sourceKey: sourceKey, pageIndex: pageIndex, maximumBytes: maximumBytes)
    announcement.release()
    guard let packet = resources.reserveDerivedBytes(descriptor.utf8Bytes * 3, priority: .passive) else {
      throw SceneRenderError.resourceLimit
    }
    do {
      let json = try await evaluate("return window.notebookRenderer.readPreparedPacket(key, index);",
        arguments: ["key": sourceKey, "index": pageIndex.map { $0 as Any } ?? NSNull()], in: web)
      try Task.checkCancellation()
      guard json.utf8.count == descriptor.utf8Bytes else { throw DocumentSessionError.invalidLayout }
      return (json, packet)
    } catch { packet.release(); throw error }
  }
}
