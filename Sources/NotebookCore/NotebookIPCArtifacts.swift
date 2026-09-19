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
  public let presented: AgentPinnedSource?
  public init(document: DocumentDocument, state: DocumentStateJournal, presented: AgentPinnedSource? = nil) throws {
    guard document.isValid, state.isValid, document.id == state.id else {
      throw CollaborationError("invalid_export_cut", "Исходник и состояние принадлежат одному документу.")
    }
    if let presented {
      try presented.validate()
      guard presented.reference.target.kind == .document, presented.reference.target.id == document.id,
        presented.image?.presentation != nil else {
        throw CollaborationError("export_presentation_unavailable", "Нужны сохранённые пиксели настоящего показанного фрагмента документа, не новый render или cache.")
      }
    }
    self.document = document; self.state = state; self.presented = presented
  }
  public func canonicalData() throws -> Data {
    _ = try Self(document: document, state: state, presented: presented)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }
  public var sha256: String { get throws {
    SHA256.hash(data: try canonicalData()).map { String(format: "%02x", $0) }.joined()
  } }
}

public struct NotebookExportOptions: Codable, Equatable, Sendable {
  public enum Format: String, Codable, Sendable { case pdf, png, svg, html, package, mp4 }
  public enum Moment: String, Codable, Sendable { case saved, presented }
  public struct Attention: Codable, Equatable, Sendable {
    public let contextID: UUID
    public let referenceID: UUID
    public init(contextID: UUID, referenceID: UUID) { self.contextID = contextID; self.referenceID = referenceID }
  }
  public let moment: Moment?
  public let attention: Attention?
  public var selectedMoment: Moment { moment ?? .saved }
  public let format: Format
  public let pageIndex: Int?
  public let pixelWidth: Int?
  public let blockID: String?
  public let video: Video?
  public struct Video: Codable, Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let framesPerSecond: Int
    public init(start: Double, end: Double, framesPerSecond: Int) { self.start = start; self.end = end; self.framesPerSecond = framesPerSecond }
    public var frameCount: Int { Int(((end-start)*Double(framesPerSecond)).rounded()) }
    public func validate() throws {
      let frames = (end-start)*Double(framesPerSecond)
      guard start.isFinite, end.isFinite, start >= 0, end > start, (1...60).contains(framesPerSecond),
        frames.isFinite, frames >= 1, frames <= 3600, abs(frames-frames.rounded()) < 0.000001 else {
        throw CollaborationError("invalid_export", "Видео требует start>=0, end>start, FPS 1…60 и целое число кадров 1…3600 в полуоткрытом диапазоне [start,end).")
      }
    }
  }
  public init(format: Format = .pdf, pageIndex: Int? = nil, pixelWidth: Int? = nil, blockID: String? = nil, video: Video? = nil, moment: Moment? = nil, attention: Attention? = nil) {
    self.moment = moment; self.attention = attention
    self.video = video; self.format = format; self.pageIndex = pageIndex; self.pixelWidth = pixelWidth; self.blockID = blockID
  }
  public func validate(cut: NotebookExportCut) throws {
    try validate()
    guard (cut.presented == nil) == (selectedMoment == .saved) else {
      throw CollaborationError("invalid_export_cut", "Выбранный момент должен совпадать с immutable cut.")
    }
    if let source = cut.presented {
      guard attention?.contextID == source.requestID, attention?.referenceID == source.id else {
        throw CollaborationError("export_presentation_mismatch", "Attention не совпадает с захваченным моментом.")
      }
      if format == .png {
        guard pixelWidth == nil || pixelWidth == source.image?.pixelWidth else {
          throw CollaborationError("export_presentation_mismatch", "Показанный PNG сохраняет точную выбранную область в её исходном разрешении; увеличить его нельзя.")
        }
      } else {
        guard let program = source.image?.presentation?.program,
          let block = cut.document.blocks.first(where: { $0.id == program.blockID && $0.kind == .interactive }),
          program.blockID == source.reference.elementID,
          program.sourceVersion == cut.document.sourceVersion(blockID: block.id),
          program.state == (cut.state.value(for: block.id) ?? block.initialState) else {
          throw CollaborationError("export_presentation_model_unavailable", "Для этого формата явно остановите программу и отправьте её attention: нужен checkpoint той же модели/source, связанный с показанными пикселями.")
        }
        if format == .pdf || format == .package || format == .mp4 {
          // Whole-document/page formats must not label another running model
          // as presented just because the selected program was checkpointed.
          guard cut.document.blocks.filter({ $0.kind == .interactive }).allSatisfy({ $0.id == program.blockID }) else {
            throw CollaborationError("export_presentation_model_unavailable", "Документ содержит другие программы без выбранного frozen checkpoint. Экспортируйте выбранный блок как SVG/HTML либо весь документ как saved.")
          }
        }
        guard blockID == nil || blockID == program.blockID else {
          throw CollaborationError("export_presentation_mismatch", "Экспортируемая программа не совпадает с выбранным кадром.")
        }
      }
    }
  }
  public func validate() throws {
    if selectedMoment == .presented {
      guard attention != nil else { throw CollaborationError("invalid_export", "Показанный момент требует attention:{contextID,referenceID}.") }
      if format == .png {
        guard pageIndex == nil, blockID == nil, video == nil,
          pixelWidth == nil || (1...4096).contains(pixelWidth!) else {
          throw CollaborationError("invalid_export", "Показанный PNG сохраняет исходный capture; область задаёт attention, не pageIndex/blockID.")
        }
        return
      }
    } else {
      guard attention == nil else { throw CollaborationError("invalid_export", "Attention относится к явно выбранному presented моменту.") }
    }
    guard format == .mp4 || video == nil else { throw CollaborationError("invalid_export", "Диапазон времени относится только к MP4.") }
    switch format {
    case .mp4:
      guard let video, let pixelWidth, pixelWidth.isMultiple(of: 2), (128...4096).contains(pixelWidth),
        let blockID, !blockID.isEmpty, blockID.utf8.count <= 120, (0..<10_000).contains(pageIndex ?? 0) else {
        throw CollaborationError("invalid_export", "MP4 требует программу, диапазон/FPS и чётную ширину 128…4096; высота выводится из канонического листа и дополняется до чётной.")
      }
      try video.validate()
    case .pdf, .package:
      guard pageIndex == nil, pixelWidth == nil, blockID == nil else { throw CollaborationError("invalid_export", "PDF/пакет сохраняют весь документ; выбор блока и пиксельный размер здесь не задаются.") }
    case .svg, .html:
      guard let blockID, !blockID.isEmpty, blockID.utf8.count <= 120, pageIndex == nil, pixelWidth == nil else {
        throw CollaborationError("invalid_export", "SVG/HTML требуют ID программы; пиксельный размер не задаётся.")
      }
    case .png:
      guard blockID == nil, (0..<10_000).contains(pageIndex ?? 0), (128...4096).contains(pixelWidth ?? 1600) else {
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
