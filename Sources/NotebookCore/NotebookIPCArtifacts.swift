import CryptoKit
import Foundation
import Darwin

public struct NotebookArtifactRequest: Codable, Sendable {
  public enum Kind: String, Codable, Sendable { case currentView, target, pageOverview, pageRegion, attention, scriptImage }
  public enum Mode: String, Codable, Sendable { case faithful, ink }
  public var kind: Kind
  public var id: UUID?
  public var regionID: String?
  public var mode: Mode?
  public var expectedSHA256: String
  public var contextID: UUID?
  public var referenceID: UUID?
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

/// One accepted source/state/assets identity. Program package hashes belong to
/// the document; their immutable namespaces cannot drift during rendering.
public struct NotebookExportCut: Codable, Equatable, Sendable {
  public let document: DocumentDocument
  public let state: DocumentStateJournal
  public init(document: DocumentDocument, state: DocumentStateJournal) throws {
    guard document.isValid, state.isValid, document.id == state.id else {
      throw CollaborationError("invalid_export_cut", "Исходник и состояние принадлежат одному документу.")
    }
    self.document = document; self.state = state
  }
  public func canonicalData() throws -> Data {
    _ = try Self(document: document, state: state)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }
  public var sha256: String { get throws {
    SHA256.hash(data: try canonicalData()).map { String(format: "%02x", $0) }.joined()
  } }
}

public struct NotebookExportOptions: Codable, Equatable, Sendable {
  public enum Format: String, Codable, Sendable { case pdf, png }
  public let format: Format
  public let pageIndex: Int?
  public let pixelWidth: Int?
  public init(format: Format = .pdf, pageIndex: Int? = nil, pixelWidth: Int? = nil) {
    self.format = format; self.pageIndex = pageIndex; self.pixelWidth = pixelWidth
  }
  public func validate() throws {
    switch format {
    case .pdf:
      guard pageIndex == nil, pixelWidth == nil else { throw CollaborationError("invalid_export", "PDF сохраняет весь физический документ; размер пикселей относится к PNG.") }
    case .png:
      guard (0..<10_000).contains(pageIndex ?? 0), (128...4096).contains(pixelWidth ?? 1600) else {
        throw CollaborationError("invalid_export", "PNG требует номер страницы >=0 и ширину от 128 до 4096 пикселей; ресурсный бюджет проверяется отдельно.")
      }
    }
  }
}

public struct NotebookExportPublication: Codable, Sendable {
  public let jobID: UUID?
  public let cut: NotebookExportCut
  public var documentID: UUID { cut.document.id }
  public var expectedRevision: String { cut.document.contentStamp.revision }
  public let source: String
  public let options: NotebookExportOptions
  public let artifact: NotebookExportFile
  public let log: String
  public let assets: [NotebookExportFile]
  public let sourceMap: DocumentPrintSourceMap?
  public let syncTeX: NotebookExportFile?
  public init(cut: NotebookExportCut, source: String, artifact: NotebookExportFile, log: String, options: NotebookExportOptions = .init(), jobID: UUID? = nil,
    assets: [NotebookExportFile] = [], sourceMap: DocumentPrintSourceMap? = nil, syncTeX: NotebookExportFile? = nil) {
    self.assets = assets
    self.sourceMap = sourceMap; self.syncTeX = syncTeX
    self.jobID = jobID
    self.cut = cut; self.source = source; self.artifact = artifact; self.options = options; self.log = log
  }
}

public struct NotebookExportReceipt: Codable, Sendable {
  public let cutSHA256: String
  public let stateRevision: String
  public let cut: NotebookArtifact
  public let documentID: UUID
  public let options: NotebookExportOptions
  public let artifact: NotebookArtifact
  public let source: NotebookArtifact?
  public let log: String
  public let packageSHA256: String?
  public let assets: [NotebookArtifact]?
  public let sourceMap: NotebookArtifact?
  public let syncTeX: NotebookArtifact?
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
    try loadActionSnapshots(actionReadModel(id))
  }

  func loadActionSnapshots(_ action: NotebookActionReadModel) throws -> [TargetRenderReceipt] {
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
    var expectedPixels: (Int, Int)?
    switch request.kind {
    case .scriptImage:
      url = root.appendingPathComponent("local/script-images/\(request.expectedSHA256).png")
      hash = request.expectedSHA256
    case .attention:
      throw CollaborationError("embedded_artifact", "Замороженные пиксели возвращаются через scriptArtifact без файлового пути.")
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
      expectedPixels = receipt.map { ($0.pixelSize.width, $0.pixelSize.height) }
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
      expectedPixels = (region.cropPixels.width, region.cropPixels.height)
    }
    guard hash == request.expectedSHA256 else { throw CollaborationError("artifact_missing", "Изображение догоняет прочитанную квитанцию.") }
    let bytes = try boundedArtifactData(url)
    guard artifactHash(bytes) == request.expectedSHA256 else {
      throw CollaborationError("artifact_missing", "Пиксели догоняют прочитанную квитанцию.")
    }
    if let expectedPixels {
      guard bytes.count >= 24, bytes.prefix(8) == Data([137,80,78,71,13,10,26,10]),
        bytes.subdata(in: 12..<16) == Data("IHDR".utf8) else {
        throw CollaborationError("invalid_artifact", "Квитанция карты требует настоящее PNG изображение.")
      }
      let width = bytes[16..<20].reduce(0) { ($0 << 8) | Int($1) }
      let height = bytes[20..<24].reduce(0) { ($0 << 8) | Int($1) }
      guard width == expectedPixels.0, height == expectedPixels.1 else {
        throw CollaborationError("invalid_artifact", "Размер изображения не соответствует геометрии прочитанной карты.")
      }
    }
    return .init(path: url.path, sha256: request.expectedSHA256, byteCount: bytes.count, mimeType: "image/png")
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
