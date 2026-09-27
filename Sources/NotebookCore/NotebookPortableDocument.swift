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
  private struct Entry: Codable {
    let id: String
    let path: String
    let text: Bool
    let byteCount: Int
    let sha256: String
  }
  private struct Manifest: Codable {
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
  private static let derivedNames: Set<String> = ["derived/document.pdf", "derived/document.synctex.gz", "derived/document.nbmap", "derived/source-map.json"]

  public init(data: Data, compilerRevision: String? = nil) throws {
    let archive = try NotebookDocumentZIP.decode(data)
    guard let metadata = archive["manifest.json"], let stateBytes = archive["state.json"] else { throw Self.invalid("В архиве нет описания или состояния документа.") }
    guard metadata.count <= Self.maximumMetadataBytes, stateBytes.count <= Self.maximumStateBytes else { throw Self.limit("Описание и история либо состояние документа превышают 8 МиБ.") }
    let manifest = try JSONDecoder().decode(Manifest.self, from: metadata)
    guard manifest.format == "NotebookDocument/1", manifest.files.count <= DocumentDocument.maximumFileCount,
      Set(manifest.files.map(\.path)).count == manifest.files.count,
      manifest.stateSHA256 == Self.hash(stateBytes) else { throw Self.invalid("Описание или состояние документа повреждено.") }
    let expected = Set(manifest.files.map { "files/"+$0.path }).union(["manifest.json", "state.json"])
    guard expected.isSubset(of: Set(archive.keys)), Set(archive.keys).subtracting(expected).isSubset(of: Self.derivedNames) else {
      throw Self.invalid("Состав ZIP не совпадает с описанием документа.")
    }
    var sourceFiles: [DocumentFile] = [], sourceBytes: [String: Data] = [:], total = 0
    for entry in manifest.files {
      try Task.checkCancellation()
      guard DocumentFile.validPath(entry.path), let bytes = archive["files/"+entry.path], bytes.count == entry.byteCount,
        bytes.count <= DocumentDocument.maximumSourceBytes-total, Self.hash(bytes) == entry.sha256 else {
        throw Self.invalid("Файл повреждён или превышает предел: \(entry.path)")
      }
      total += bytes.count; sourceBytes[entry.path] = bytes
      if entry.text {
        guard bytes.count <= DocumentFile.maximumSourceLength, let source = String(data: bytes, encoding: .utf8) else { throw Self.invalid("Текст файла не является UTF-8.") }
        sourceFiles.append(.init(id: entry.id, path: entry.path, source: source))
      } else { sourceFiles.append(.init(id: entry.id, path: entry.path, resource: Self.resource(path: entry.path, bytes: bytes))) }
    }
    var value: JSONValue = .object(["format": .number(Double(DocumentDocument.formatVersion)), "id": .string(manifest.documentID.uuidString),
      "entrypoint": .string(manifest.entrypoint), "contentStamp": try .encode(manifest.contentStamp), "files": try .encode(sourceFiles)])
    if let collaboration = manifest.collaboration { value = value.setting("collaboration", try .encode(collaboration)) }
    let document = try value.decode(DocumentDocument.self), state = try JSONDecoder().decode(DocumentStateJournal.self, from: stateBytes)
    let exactCut = try NotebookExportCut(document: document, state: state, presented: manifest.presented)
    try Self.validateCutBudget(exactCut)
    cut = exactCut; files = sourceBytes
    // Derived bytes are optional and disposable. An older compiler never makes
    // the received source unreadable or turns a stale cache into current proof.
    var accepted: Derived?
    if let compilerRevision, let hashes = manifest.derived, Set(hashes.keys) == Self.derivedNames,
      Self.derivedNames.allSatisfy({ name in archive[name].map { Self.hash($0) == hashes[name] } ?? false }),
      archive["derived/source-map.json"]!.count <= Self.maximumMetadataBytes,
      let map = try? JSONDecoder().decode(DocumentPrintSourceMap.self, from: archive["derived/source-map.json"]!) {
      let candidate = Derived(pdf: archive["derived/document.pdf"]!, syncTeX: archive["derived/document.synctex.gz"]!,
        interactiveMap: archive["derived/document.nbmap"]!, sourceMap: map)
      if (try? candidate.validate(document: document, compilerRevision: compilerRevision)) != nil { accepted = candidate }
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
  fileprivate static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  fileprivate static func invalid(_ message: String) -> CollaborationError { .init("invalid_portable_document", message) }
  private static func limit(_ message: String) -> CollaborationError { .init("resource_limit", message) }
}

public struct NotebookPortableImportResult: Sendable {
  public let documentID: UUID
  public let receipt: CollaborationReceipt
  public let derived: NotebookPortableDocument.Derived?
}
extension NotebookStore {
  public func exportPortableDocument(cut: NotebookExportCut, derived: NotebookPortableDocument.Derived? = nil) throws -> Data {
    var files: [String: Data] = [:]
    for file in cut.document.files { try Task.checkCancellation(); files[file.path] = try readDocumentFileBytes(file) }
    return try NotebookPortableDocument.encode(cut: cut, files: files, derived: derived)
  }
  /// Decode before acquiring the writer. The one existing create action owns
  /// content, state, catalogue, board placement, delivery and Undo together.
  public func importPortableDocument(data: Data, targetBoardID: UUID, center: WorldPoint, actor: UUID,
    compilerRevision: String? = nil, requestID: UUID = UUID()) throws -> NotebookPortableImportResult {
    let archive = try NotebookPortableDocument(data: data, compilerRevision: compilerRevision)
    let id = Self.submissionID(requestID, suffix: "document")
    let fingerprint = try collaborationHash(JSONValue.object(["domain": .string("NotebookDocumentImport/1"),
      "archive": .string(NotebookPortableDocument.hash(data)), "boardID": .string(targetBoardID.uuidString.lowercased()), "center": try .encode(center)]))
    let original = archive.cut.document
    var state = DocumentStateJournal(id: id, actor: actor)
    for record in archive.cut.state.records { _ = state.commit(instanceID: record.id, value: record.value, actor: actor) }
    let target = CollaborationTarget(kind: .board, id: targetBoardID)
    let operation = CollaborationOperation(kind: .createDocument, target: target, id: id.uuidString.lowercased(),
      values: ["title": .string("Импортированный документ"), "center": try .encode(center), "entrypoint": .string(original.entrypoint),
        "files": try .encode(original.files), "state": try .encode(state)])
    let receipt = try commandTransaction(readAllowance: .agentCommand) {
      for file in original.files where file.resource != nil {
        let bytes = archive.files[file.path]!
        for offset in stride(from: 0, to: bytes.count, by: NotebookProgramPackage.partBytes) {
          _ = try currentSQL!.putBlob(bytes.subdata(in: offset..<min(offset+NotebookProgramPackage.partBytes, bytes.count)))
        }
      }
      let saved = try hasStoredValue("collaboration/actions/"+requestID.uuidString.lowercased()+".json")
      let expected: [CollaborationExpectation] = try saved ? [] : readBasis(targets: [target,
        .init(kind: .workspace, id: workspaceHeader().rootBoardID)]).owners
      return try applyCollaborationActionImmediately(.init(id: requestID, summary: "Импорт документа", expected: expected, operations: [operation]),
        actor: actor, requestFingerprint: fingerprint, human: true)
    }
    let imported = try loadDocument(id)
    return .init(documentID: id, receipt: receipt, derived: archive.derived.flatMap { try? $0.rebinding(to: imported) })
  }
}
