import CryptoKit
import Foundation

/// One .notex ZIP. Files remain ordinary source bytes; the manifest names
/// them without duplicating text or introducing a second document model.
public struct NotebookPortableDocument: Sendable {
  static let maximumMetadataBytes = 8*1024*1024
  static let maximumStateBytes = 8*1024*1024
  public struct Derived: Sendable {
    public let pdf: Data
    public let syncTeX: Data
    public let interactiveMap: Data
    public let sourceMap: DocumentPrintSourceMap
    public init(pdf: Data, syncTeX: Data, interactiveMap: Data, sourceMap: DocumentPrintSourceMap) {
      self.pdf = pdf; self.syncTeX = syncTeX; self.interactiveMap = interactiveMap; self.sourceMap = sourceMap
    }
    public func validate(document: DocumentDocument, compilerRevision: String) throws {
      guard sourceMap.compilerRevision == compilerRevision, pdf.starts(with: Data("%PDF-".utf8)), pdf.count <= 16*1024*1024,
        syncTeX.starts(with: Data([0x1f, 0x8b])), syncTeX.count <= 4*1024*1024, interactiveMap.count <= 4*1024*1024,
        let source = document.files.first(where: { $0.path == document.entrypoint && $0.resource == nil })?.source else {
        throw NotebookPortableDocument.invalid("Производная сборка не подходит к исходнику или компилятору.")
      }
      try sourceMap.validate(document: document, source: source, pdf: pdf)
    }
    public func rebinding(to document: DocumentDocument) throws -> Self {
      guard let source = document.files.first(where: { $0.path == document.entrypoint && $0.resource == nil })?.source else {
        throw NotebookPortableDocument.invalid("Главный исходник отсутствует.")
      }
      let map = try DocumentPrintSourceMap(document: document, source: source, pdf: pdf, compilerRevision: sourceMap.compilerRevision)
      guard map.inputSHA256 == sourceMap.inputSHA256 else { throw NotebookPortableDocument.invalid("Исходные файлы изменились при переносе.") }
      return .init(pdf: pdf, syncTeX: syncTeX, interactiveMap: interactiveMap, sourceMap: map)
    }
  }
  struct Entry: Codable, Sendable {
    let id: String
    let path: String
    let text: Bool
    let byteCount: Int
    let sha256: String
  }
  struct Manifest: Codable, Sendable {
    let format: String
    let documentID: UUID
    let entrypoint: String
    let contentStamp: VersionStamp
    let collaboration: CollaborativeContent?
    let files: [Entry]
    let stateSHA256: String
    let presented: AgentPinnedSource?
    var derived: [String: String]?
  }
  public let cut: NotebookExportCut
  /// Authored paths, without the transport's files/ prefix.
  public let files: [String: Data]
  public let derived: Derived?
  static let derivedNames: Set<String> = ["derived/document.pdf", "derived/document.synctex.gz", "derived/document.nbmap", "derived/source-map.json"]

  public init(data: Data, compilerRevision: String? = nil) throws {
    let archive = try NotebookDocumentZIP.Archive(data: data)
    guard let metadataEntry = archive.entry("manifest.json"), let stateEntry = archive.entry("state.json"),
      metadataEntry.size <= Self.maximumMetadataBytes, stateEntry.size <= Self.maximumStateBytes else {
      throw Self.invalid("В архиве нет допустимого описания или состояния документа.")
    }
    let metadata = try archive.data(metadataEntry, maximumBytes: Self.maximumMetadataBytes)
    let stateBytes = try archive.data(stateEntry, maximumBytes: Self.maximumStateBytes)
    let maximum = NotebookPortableDocumentImport.maximumPreparationBytes
    let buffers = data.count + archive.retainedDirectoryBytes + metadata.count + stateBytes.count + 2*1_048_576
    let metadataDecode = try NotebookJSONAdmission.allocationCost(metadata, maximumBytes: maximum-buffers)
    let stateDecode = try NotebookJSONAdmission.allocationCost(stateBytes, maximumBytes: maximum-buffers-metadataDecode)
    let manifest = try JSONDecoder().decode(Manifest.self, from: metadata)
    guard manifest.format == "NotebookDocument/1", manifest.files.count <= DocumentDocument.maximumFileCount,
      Set(manifest.files.map(\.path)).count == manifest.files.count,
      manifest.stateSHA256 == Self.hash(stateBytes) else { throw Self.invalid("Описание или состояние документа повреждено.") }
    let expected = Set(manifest.files.map { "files/"+$0.path }).union(["manifest.json", "state.json"])
    guard expected.isSubset(of: Set(archive.entries.map(\.path))),
      Set(archive.entries.map(\.path)).subtracting(expected).isSubset(of: Self.derivedNames) else {
      throw Self.invalid("Состав ZIP не совпадает с описанием документа.")
    }
    var total = 0, largest = 0
    for entry in manifest.files {
      guard entry.byteCount >= 0, entry.byteCount <= DocumentDocument.maximumSourceBytes-total,
        !entry.text || entry.byteCount <= DocumentFile.maximumSourceLength,
        DocumentFile.validPath(entry.path), archive.entry("files/"+entry.path)?.size == entry.byteCount else {
        throw Self.invalid("Файл повреждён или превышает предел: \(entry.path)")
      }
      total += entry.byteCount; largest = max(largest,entry.byteCount)
    }
    let sourceBudget = buffers+metadataDecode+stateDecode+total*3+largest*2
    guard sourceBudget <= maximum else { throw NotebookPortableDocumentImport.refusal() }
    var sourceFiles: [DocumentFile] = [], sourceBytes: [String: Data] = [:], textWire = 0
    for entry in manifest.files {
      try Task.checkCancellation()
      let bytes = try archive.data(archive.entry("files/"+entry.path)!, maximumBytes: DocumentDocument.maximumSourceBytes)
      guard Self.hash(bytes) == entry.sha256 else { throw Self.invalid("SHA-256 файла не совпадает: \(entry.path)") }
      sourceBytes[entry.path] = bytes
      if entry.text {
        guard let source = String(data: bytes, encoding: .utf8) else { throw Self.invalid("Текст файла не является UTF-8.") }
        // Only an optional source-map hash needs this encoded buffer. A text
        // source itself remains raw UTF-8, including controls and embedded NUL.
        textWire += source.utf8.reduce(2) { bytes, byte in
          bytes + (byte < 0x20 ? 6 : byte == 34 || byte == 92 || byte == 47 ? 2 : 1)
        }
        sourceFiles.append(.init(id: entry.id, path: entry.path, source: source))
      } else { sourceFiles.append(.init(id: entry.id, path: entry.path, resource: Self.resource(path: entry.path, bytes: bytes))) }
    }
    let document = try DocumentDocument(importedID: manifest.documentID, entrypoint: manifest.entrypoint,
      files: sourceFiles, contentStamp: manifest.contentStamp, collaboration: manifest.collaboration)
    let state = try JSONDecoder().decode(DocumentStateJournal.self, from: stateBytes)
    let exactCut = try NotebookExportCut(document: document, state: state, presented: manifest.presented)
    try Self.validateCutBudget(exactCut)
    cut = exactCut; files = sourceBytes
    let cacheEntries = archive.entries.filter { Self.derivedNames.contains($0.path) }
    let derivedBytes = cacheEntries.reduce(0) { $0+$1.size }, codec = 2*(metadata.count*2+textWire)
    var candidates: [String: Data] = [:]
    var candidateAllowed = compilerRevision != nil && Set(manifest.derived?.keys.map { $0 } ?? []) == Self.derivedNames
      && cacheEntries.count == Self.derivedNames.count
      && (archive.entry("derived/document.pdf")?.size ?? Int.max) <= 16*1_048_576
      && (archive.entry("derived/document.synctex.gz")?.size ?? Int.max) <= 4*1_048_576
      && (archive.entry("derived/document.nbmap")?.size ?? Int.max) <= 4*1_048_576
      && (archive.entry("derived/source-map.json")?.size ?? Int.max) <= Self.maximumMetadataBytes
      && sourceBudget+derivedBytes*2+codec <= maximum
    for entry in cacheEntries {
      if candidateAllowed {
        let value = try archive.data(entry, maximumBytes: entry.size)
        if Self.hash(value) == manifest.derived?[entry.path] { candidates[entry.path] = value }
        else { candidateAllowed = false; candidates.removeAll() }
      } else { try archive.consume(entry) { _ in } }
    }
    var accepted: Derived?
    if candidateAllowed, let compilerRevision, let mapBytes = candidates["derived/source-map.json"] {
      do {
        _ = try NotebookJSONAdmission.allocationCost(mapBytes,
          maximumBytes: maximum-sourceBudget-derivedBytes-codec)
        let map = try JSONDecoder().decode(DocumentPrintSourceMap.self, from: mapBytes)
        let candidate = Derived(pdf: candidates["derived/document.pdf"]!, syncTeX: candidates["derived/document.synctex.gz"]!,
          interactiveMap: candidates["derived/document.nbmap"]!, sourceMap: map)
        try candidate.validate(document: document, compilerRevision: compilerRevision)
        accepted = candidate
      } catch is CancellationError { throw CancellationError() }
      catch { /* A derived cache cannot make the authored source unavailable. */ }
    }
    derived = accepted
  }

  fileprivate static func encode(cut: NotebookExportCut, files: [String: Data], derived: Derived?) throws -> Data {
    try validateCutBudget(cut)
    guard Set(files.keys) == Set(cut.document.files.map(\.path)) else { throw invalid("Не все исходные файлы доступны.") }
    var archive: [String: Data] = [:], entries: [Entry] = []
    for file in cut.document.files.sorted(by: { $0.path < $1.path }) {
      guard let bytes = files[file.path], bytes.count == file.byteCount else { throw invalid("Размер исходника не совпадает.") }
      if file.resource == nil { guard bytes == Data(file.source.utf8) else { throw invalid("Текст исходника изменился.") } }
      else { guard resource(path: file.path, bytes: bytes) == file.resource else { throw invalid("Ресурс изменился.") } }
      archive["files/"+file.path] = bytes
      entries.append(.init(id: file.id, path: file.path, text: file.resource == nil, byteCount: bytes.count, sha256: hash(bytes)))
    }
    let state = try encode(cut.state)
    archive["state.json"] = state
    var manifest = Manifest(format: "NotebookDocument/1", documentID: cut.document.id, entrypoint: cut.document.entrypoint,
      contentStamp: cut.document.contentStamp, collaboration: cut.document.collaboration, files: entries,
      stateSHA256: hash(state), presented: cut.presented, derived: nil)
    let metadata = try encode(manifest)
    guard metadata.count <= maximumMetadataBytes else { throw limit("Описание и причинная история превышают 8 МиБ.") }
    archive["manifest.json"] = metadata
    // A precompiled cache is optional. Never reject transferable sources merely
    // because the finished PDF or the combined archive exceeds its cache budget.
    if let derived, (try? derived.validate(document: cut.document, compilerRevision: derived.sourceMap.compilerRevision)) != nil {
      let values = ["derived/document.pdf": derived.pdf, "derived/document.synctex.gz": derived.syncTeX,
        "derived/document.nbmap": derived.interactiveMap, "derived/source-map.json": try encode(derived.sourceMap)]
      manifest.derived = values.mapValues(hash)
      let metadata = try encode(manifest)
      var candidate = archive.merging(values) { _, rhs in rhs }
      candidate["manifest.json"] = metadata
      if metadata.count <= maximumMetadataBytes, values["derived/source-map.json"]!.count <= maximumMetadataBytes,
        NotebookDocumentZIP.isWithinSizeBudget(candidate) { archive = candidate }
    }
    return try NotebookDocumentZIP.encode(archive)
  }
  /// The raw authored bytes have their own 16 MiB model budget. JSON escaping
  /// is not more content, and a cut must not inherit the old 8 MiB block cap.
  /// Causal frontiers retain their exact existing values, bounded as metadata.
  static func validateCutBudget(_ cut: NotebookExportCut) throws {
    _ = try NotebookExportCut(document: cut.document, state: cut.state, presented: cut.presented)
    guard try encode(cut.state).count <= maximumStateBytes else { throw limit("Состояние превышает 8 МиБ.") }
    struct Metadata: Encodable {
      let id: UUID
      let entrypoint: String
      let contentStamp: VersionStamp
      let collaboration: CollaborativeContent?
      let files: [DocumentFile]
      let presented: AgentPinnedSource?
    }
    let document = cut.document
    let metadata = Metadata(id: document.id, entrypoint: document.entrypoint, contentStamp: document.contentStamp,
      collaboration: document.collaboration, files: document.files.map {
        .init(id: $0.id, path: $0.path, resource: $0.resource)
      }, presented: cut.presented)
    guard try encode(metadata).count <= maximumMetadataBytes else { throw limit("Описание и причинная история превышают 8 МиБ.") }
  }
  fileprivate static func resource(path: String, bytes: Data) -> NotebookProgramPackage.File {
    let parts = stride(from: 0, to: bytes.count, by: NotebookProgramPackage.partBytes).map { offset in
      let part = bytes.subdata(in: offset..<min(offset+NotebookProgramPackage.partBytes, bytes.count))
      return NotebookProgramPackage.Part(sha256: hash(part), byteCount: part.count)
    }
    return .init(path: path, mimeType: NotebookProgramPackage.mimeType(for: path), byteCount: Int64(bytes.count), parts: parts)
  }
  fileprivate static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value)
  }
  static func hash(_ data: Data) -> String { NotebookHexEncoding.encode(SHA256.hash(data: data)) }
  fileprivate static func invalid(_ message: String) -> CollaborationError { .init("invalid_portable_document", message) }
  private static func limit(_ message: String) -> CollaborationError { .init("resource_limit", message) }
}

extension NotebookStore {
  public func exportPortableDocument(cut: NotebookExportCut, derived: NotebookPortableDocument.Derived? = nil) throws -> Data {
    var files: [String: Data] = [:]
    for file in cut.document.files { try Task.checkCancellation(); files[file.path] = try readDocumentFileBytes(file) }
    return try NotebookPortableDocument.encode(cut: cut, files: files, derived: derived)
  }
}
