import CryptoKit
import Foundation
import Darwin

public struct NotebookArtifactRequest: Codable, Sendable {
  public enum Kind: String, Codable, Sendable { case currentView, target, pageOverview, pageRegion }
  public enum Mode: String, Codable, Sendable { case faithful, ink }
  public var kind: Kind
  public var id: UUID?
  public var regionID: String?
  public var mode: Mode?
  public var expectedSHA256: String
  public init(kind: Kind, id: UUID? = nil, regionID: String? = nil, mode: Mode? = nil, expectedSHA256: String) {
    self.kind = kind; self.id = id; self.regionID = regionID; self.mode = mode; self.expectedSHA256 = expectedSHA256
  }
}

/// This is the only filesystem capability returned to MCP: one verified derived file.
public struct NotebookArtifact: Codable, Sendable {
  public let path: String
  public let sha256: String
  public let byteCount: Int
  public let mimeType: String
}

public struct NotebookRuntimeStatus: Codable, Sendable {
  public let status: String
  public let updatedAt: TimeInterval
  public init(status: String, updatedAt: TimeInterval = Date().timeIntervalSince1970) {
    self.status = status; self.updatedAt = updatedAt
  }
}

public struct NotebookExportPublication: Codable, Sendable {
  public let documentID: UUID
  public let expectedRevision: String
  public let source: String
  public let pdf: Data
  public let log: String
  public init(documentID: UUID, expectedRevision: String, source: String, pdf: Data, log: String) {
    self.documentID = documentID; self.expectedRevision = expectedRevision; self.source = source; self.pdf = pdf; self.log = log
  }
}

public struct NotebookExportReceipt: Codable, Sendable {
  public let documentID: UUID
  public let texPath: String
  public let pdfPath: String
  public let pdfSHA256: String
  public let byteCount: Int
  public let log: String
}

extension NotebookStore {
  public func loadCurrentViewReceipt() throws -> CurrentViewReceipt? {
    guard let receipt: CurrentViewReceipt = try readDerivative(currentViewRevisionURL) else { return nil }
    guard receipt.isValid else { throw CollaborationError("invalid_artifact", "Квитанция текущего вида повреждена.") }
    return receipt
  }

  public func loadPageVisionReceipt(_ id: UUID, revision: String? = nil) throws -> PageVisionReceipt? {
    let url: URL
    if let revision {
      let parts = revision.split(separator: "@", omittingEmptySubsequences: false)
      guard parts.count == 2, let counter = UInt64(parts[0]), let actor = UUID(uuidString: String(parts[1])) else {
        throw CollaborationError("invalid_reference", "Версия карты содержит счётчик и UUID автора.")
      }
      url = previewVisionHistoryURL(id).appendingPathComponent("\(counter)-\(actor.uuidString.lowercased()).json")
    } else { url = previewVisionReceiptURL(id) }
    guard let receipt: PageVisionReceipt = try readDerivative(url) else { return nil }
    guard receipt.isValid, receipt.pageID == id else {
      throw CollaborationError("invalid_artifact", "Квитанция карты листа повреждена.")
    }
    return receipt
  }

  public func loadTargetRenderReceipt(_ id: UUID) throws -> TargetRenderReceipt? {
    guard let receipt: TargetRenderReceipt = try readDerivative(targetReceiptURL(id)) else { return nil }
    guard receipt.request.id == id, ["ready", "error"].contains(receipt.status) else {
      throw CollaborationError("invalid_artifact", "Квитанция целевого снимка повреждена.")
    }
    return receipt
  }

  public func loadActionSnapshots(_ id: UUID) throws -> [TargetRenderReceipt] {
    let action = try collaborationAction(id)
    return try targetRenderRequests().compactMap { request in
      guard action.revisions.contains(where: { $0.target == request.target }),
        let receipt = try loadTargetRenderReceipt(request.id), receipt.status == "ready", receipt.pngSHA256 != nil else { return nil }
      return receipt
    }
  }

  public func loadRuntimeStatus() throws -> NotebookRuntimeStatus? {
    try readDerivative(root.appendingPathComponent("previews/runtime.json"))
  }

  public func authorizedArtifact(_ request: NotebookArtifactRequest) throws -> NotebookArtifact {
    guard request.expectedSHA256.count == 64,
      request.expectedSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
      throw CollaborationError("invalid_artifact", "Изображение требует прочитанный SHA-256.")
    }
    let url: URL
    let hash: String?
    switch request.kind {
    case .currentView:
      url = currentViewPreviewURL; hash = try loadCurrentViewReceipt()?.pngSHA256
    case .target:
      let id = try artifactID(request.id)
      url = targetPNGURL(id); hash = try loadTargetRenderReceipt(id)?.pngSHA256
    case .pageOverview:
      let id = try artifactID(request.id), receipt = try loadPageVisionReceipt(id)
      let ink = request.mode == .ink
      url = ink ? previewInkURL(id) : previewURL(id)
      hash = ink ? receipt?.inkPNG_SHA256 : receipt?.previewPNG_SHA256
    case .pageRegion:
      let id = try artifactID(request.id)
      guard let regionID = request.regionID,
        let receipt = try loadPageVisionReceipt(id),
        let region = receipt.regions.first(where: { $0.id == regionID }) else {
        throw CollaborationError("artifact_missing", "Область отсутствует в готовой карте.")
      }
      // The ID comes from a validated receipt, never from a relative client path.
      let ink = request.mode == .ink
      url = previewRegionsURL(id).appendingPathComponent("\(region.id).\(ink ? "ink" : "faithful").png")
      hash = ink ? region.inkPNG_SHA256 : region.faithfulPNG_SHA256
    }
    guard hash == request.expectedSHA256 else { throw CollaborationError("artifact_missing", "Изображение догоняет прочитанную квитанцию.") }
    let bytes = try boundedArtifactData(url)
    guard artifactHash(bytes) == request.expectedSHA256 else {
      throw CollaborationError("artifact_missing", "Пиксели догоняют прочитанную квитанцию.")
    }
    return .init(path: url.path, sha256: request.expectedSHA256, byteCount: bytes.count, mimeType: "image/png")
  }

  public func publishDocumentExport(_ publication: NotebookExportPublication) throws -> NotebookExportReceipt {
    let document = try loadDocument(publication.documentID)
    guard document.contentStamp.revision == publication.expectedRevision else {
      throw CollaborationError("revision_conflict", "Документ изменился во время печати.")
    }
    guard publication.source.utf8.count <= 4 * 1_024 * 1_024,
      publication.pdf.count <= 16 * 1_024 * 1_024,
      publication.pdf.starts(with: Data("%PDF-".utf8)), publication.log.utf8.count <= 32_000 else {
      throw CollaborationError("invalid_artifact", "Печатный результат должен содержать PDF до 16 МиБ и исходник до 4 МиБ.")
    }
    // Content-addressed names prevent a later export replacing an already returned artifact.
    let hash = artifactHash(publication.pdf)
    let directory = root.appendingPathComponent("exports", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stem = publication.documentID.uuidString.lowercased() + "-" + hash
    let tex = directory.appendingPathComponent(stem + ".tex"), pdf = directory.appendingPathComponent(stem + ".pdf")
    try Data(publication.source.utf8).write(to: tex, options: .atomic)
    try publication.pdf.write(to: pdf, options: .atomic)
    return .init(documentID: publication.documentID, texPath: tex.path, pdfPath: pdf.path,
      pdfSHA256: hash, byteCount: publication.pdf.count, log: publication.log)
  }

  private func artifactID(_ id: UUID?) throws -> UUID {
    guard let id else { throw CollaborationError("invalid_artifact", "Изображение имеет устойчивый ID владельца.") }; return id
  }

  private func readDerivative<T: Decodable>(_ url: URL) throws -> T? {
    let data: Data
    do { data = try boundedArtifactData(url, maximum: 8 * 1_024 * 1_024) }
    catch let error as CollaborationError where error.code == "artifact_missing" { return nil }
    do { return try JSONDecoder().decode(T.self, from: data) }
    catch { throw CollaborationError("invalid_artifact", "Производная квитанция повреждена: \(url.lastPathComponent).") }
  }

  private func boundedArtifactData(_ url: URL, maximum: Int = 64 * 1_024 * 1_024) throws -> Data {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    guard resolved.path.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
      throw CollaborationError("invalid_artifact", "Производный файл вышел за корень своего владельца.")
    }
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else {
      if errno == ENOENT { throw CollaborationError("artifact_missing", "Производный файл ещё не опубликован.") }
      throw CollaborationError("invalid_artifact", "Производный файл недоступен.")
    }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= maximum else {
      throw CollaborationError("resource_limit", "Производный файл превышает допустимый размер.")
    }
    var result = Data(count: Int(info.st_size))
    let count = result.withUnsafeMutableBytes { buffer -> Int in
      var offset = 0
      while offset < buffer.count {
        let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return -1 }
        offset += n
      }
      return offset
    }
    guard count == result.count else { throw CollaborationError("artifact_missing", "Публикация изображения ещё не завершена.") }
    return result
  }

  private func artifactHash(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
}
