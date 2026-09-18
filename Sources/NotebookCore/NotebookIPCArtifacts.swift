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

public struct NotebookExportAsset: Codable, Sendable {
  public let name: String
  public let data: Data
  public init(name: String, data: Data) { self.name = name; self.data = data }
}

public struct NotebookExportPublication: Codable, Sendable {
  public let jobID: UUID?
  public let documentID: UUID
  public let expectedRevision: String
  public let source: String
  public let pdf: Data
  public let log: String
  public let assets: [NotebookExportAsset]?
  public let sourceMap: DocumentPrintSourceMap?
  public let syncTeX: Data?
  public init(documentID: UUID, expectedRevision: String, source: String, pdf: Data, log: String, jobID: UUID? = nil,
    assets: [NotebookExportAsset] = [], sourceMap: DocumentPrintSourceMap? = nil, syncTeX: Data? = nil) {
    self.assets = assets
    self.sourceMap = sourceMap; self.syncTeX = syncTeX
    self.jobID = jobID
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

  public func publishDocumentExport(_ publication: NotebookExportPublication) throws -> NotebookExportReceipt {
    // Decode/render/hash/write preparation never holds a SQL transaction. Only
    // revision admission, atomic installation and the durable receipt use the writer.
    let prepared = try prepareDocumentExport(publication)
    defer { try? FileManager.default.removeItem(at: prepared.staging) }
    return try commandTransaction(advancesReadRevision: false, readAllowance: .agentCommand) {
      if let id = publication.jobID, let saved = try scriptExportJob(id), saved["status"] == .string("saved"),
        let receipt = saved["receipt"] { return try receipt.decode(NotebookExportReceipt.self) }
      let document = try loadDocument(publication.documentID)
      guard document.contentStamp.revision == publication.expectedRevision,
        prepared.document.map({ $0 == document }) ?? true else {
        throw CollaborationError("revision_conflict", "Документ изменился во время печати.")
      }
      if !prepared.alreadyInstalled {
        try FileManager.default.moveItem(at: prepared.staging, to: prepared.destination)
      }
      let receipt = prepared.receipt
      if let id = publication.jobID {
        try saveScriptExportJob(id, value: .object(["status": .string("saved"), "jobID": .string(id.uuidString.lowercased()),
          "contentRevision": .string(publication.expectedRevision), "receipt": try .encode(receipt)]))
      }
      return receipt
    }
  }

  private func prepareDocumentExport(_ publication: NotebookExportPublication) throws ->
    (staging: URL, destination: URL, alreadyInstalled: Bool, receipt: NotebookExportReceipt, document: DocumentDocument?) {
    guard currentSQL == nil else { throw NotebookStorageError.invalidTransaction("Export preparation must precede SQL admission") }
    let assets = publication.assets ?? []
    let assetBytes = assets.reduce(0) { $0 + $1.data.count }
    guard publication.source.utf8.count <= 4*1024*1024,
      publication.pdf.count <= 16*1024*1024, publication.pdf.starts(with: Data("%PDF-".utf8)),
      publication.log.utf8.count <= 32_000, assets.count <= 128,
      Set(assets.map(\.name)).count == assets.count, assetBytes <= 8*1024*1024,
      assetBytes + publication.pdf.count <= 17*1024*1024,
      assets.enumerated().allSatisfy({ index, asset in
        asset.name == "notebook-image-\(index).pdf" && asset.data.starts(with: Data("%PDF-".utf8))
      }) else { throw CollaborationError("invalid_artifact", "Недопустимый или слишком большой печатный пакет.") }
    var files = [("document.tex", Data(publication.source.utf8)), ("document.pdf", publication.pdf)]
      + assets.map { ($0.name, $0.data) }
    let snapshot: DocumentDocument?
    if let map = publication.sourceMap, let syncTeX = publication.syncTeX {
      guard syncTeX.count <= 4*1024*1024, syncTeX.starts(with: [0x1f, 0x8b]) else {
        throw CollaborationError("invalid_artifact", "Недопустимая или слишком большая карта печатных страниц.")
      }
      let document = try loadDocument(publication.documentID)
      try map.validate(document: document, source: publication.source, pdf: publication.pdf)
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let encoded = try encoder.encode(map)
      guard encoded.count <= 1024*1024 else { throw CollaborationError("invalid_artifact", "Карта блоков превышает 1 МиБ.") }
      files += [("document.source-map.json", encoded), ("document.synctex.gz", syncTeX)]
      snapshot = document
    } else {
      guard publication.sourceMap == nil, publication.syncTeX == nil else {
        throw CollaborationError("invalid_artifact", "Карта блоков и карта страниц публикуются вместе.")
      }
      snapshot = nil
    }
    // Length-framed names and content hashes bind the entire package, including
    // TeX sources that happen to compile to identical PDF pixels.
    var digest = SHA256()
    for (name, data) in files {
      let nameData = Data(name.utf8)
      var length = UInt64(nameData.count).bigEndian
      withUnsafeBytes(of: &length) { digest.update(data: Data($0)) }
      digest.update(data: nameData)
      var size = UInt64(data.count).bigEndian
      withUnsafeBytes(of: &size) { digest.update(data: Data($0)) }
      digest.update(data: Data(SHA256.hash(data: data)))
    }
    let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
    let directory = root.appendingPathComponent("exports", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(publication.documentID.uuidString.lowercased() + "-" + hash, isDirectory: true)
    let alreadyInstalled = FileManager.default.fileExists(atPath: destination.path)
    // The serial writer owns this directory even before entering SQL. Verify
    // an existing immutable package here, so repeated publication never reads
    // or compares megabytes while a database transaction is open.
    if alreadyInstalled {
      for (name, data) in files {
        guard try Data(contentsOf: destination.appendingPathComponent(name)) == data else {
          throw CollaborationError("invalid_artifact", "Сохранённый печатный пакет не соответствует своему отпечатку.")
        }
      }
    }
    let staging = directory.appendingPathComponent(".pending-" + UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do { for (name, data) in files { try data.write(to: staging.appendingPathComponent(name), options: .atomic) } }
    catch { try? FileManager.default.removeItem(at: staging); throw error }
    func artifact(_ name: String, type: String) -> NotebookArtifact? {
      files.first { $0.0 == name }.map { .init(path: destination.appendingPathComponent(name).path,
        sha256: artifactHash($0.1), byteCount: $0.1.count, mimeType: type) }
    }
    let receipt = NotebookExportReceipt(documentID: publication.documentID,
      texPath: destination.appendingPathComponent("document.tex").path,
      pdfPath: destination.appendingPathComponent("document.pdf").path,
      pdfSHA256: artifactHash(publication.pdf), byteCount: publication.pdf.count, log: publication.log,
      packageSHA256: hash, assets: assets.map { .init(path: destination.appendingPathComponent($0.name).path,
        sha256: artifactHash($0.data), byteCount: $0.data.count, mimeType: "application/pdf") },
      sourceMap: artifact("document.source-map.json", type: "application/json"),
      syncTeX: artifact("document.synctex.gz", type: "application/gzip"))
    return (staging, destination, alreadyInstalled, receipt, snapshot)
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
