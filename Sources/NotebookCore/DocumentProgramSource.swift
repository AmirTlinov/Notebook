import Foundation

/// A disposable execution descriptor made from one immutable document cut.
/// Files remain the only editable source; layout never enters execution identity.
public struct DocumentProgramSource: Equatable, Sendable {
  public let id: String
  public let path: String
  public let programPackage: String
  public let initialState: JSONValue
  public let sourceBasis: String
  public let package: NotebookProgramPackage
  fileprivate var stagedText: [String: Data]

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.path == rhs.path && lhs.programPackage == rhs.programPackage
      && lhs.initialState == rhs.initialState && lhs.sourceBasis == rhs.sourceBasis
  }

  public init(document: DocumentDocument, instanceID: String, path: String) throws {
    guard !instanceID.isEmpty, instanceID.utf16.count <= 120, DocumentFile.validPath(path) else {
      throw CollaborationError("invalid_program", "Программа требует ID экземпляра и относительный путь.")
    }
    self.id = instanceID; self.path = path
    let configPath = path + "/program.json"
    let (config, dependencies) = try Self.configuration(document.files.first { $0.path == configPath })
    let files = document.files.filter { $0.path.hasPrefix(path + "/") || dependencies.contains($0.path) }.sorted { $0.path < $1.path }
    guard dependencies.allSatisfy({ dependency in files.contains { $0.path == dependency } }) else {
      throw CollaborationError("missing_resource", "Не найден файл зависимости программы \(path).")
    }
    func entry(_ key: String, _ fallback: String) throws -> String? {
      if config[key] == .null { return nil }
      let relative = config[key]?.string ?? fallback
      guard DocumentFile.validPath(relative) else { throw CollaborationError("invalid_program", "Недопустимый входной файл программы.") }
      let entry = path + "/" + relative
      guard files.contains(where: { $0.path == entry }) else {
        if config[key] != nil { throw CollaborationError("missing_resource", "Не найден \(entry).") }
        return nil
      }
      return entry
    }
    var text: [String: Data] = [:]
    let descriptors = files.map { file -> NotebookProgramPackage.File in
      if let resource = file.resource { return resource }
      let data = Data(file.source.utf8)
      var parts: [NotebookProgramPackage.Part] = []
      for offset in stride(from: 0, to: data.count, by: NotebookProgramPackage.partBytes) {
        let bytes = data.subdata(in: offset..<min(data.count, offset + NotebookProgramPackage.partBytes))
        let hash = NotebookProgramPackage.hash(bytes); text[hash] = bytes
        parts.append(.init(sha256: hash, byteCount: bytes.count))
      }
      return .init(path: file.path, mimeType: file.mimeType, byteCount: file.byteCount, parts: parts)
    }
    package = try .init(html: entry("html", "index.html"), css: entry("css", "style.css"),
      javaScript: entry("javaScript", "main.js"), module: config["module"]?.decode(Bool.self) ?? true, files: descriptors)
    programPackage = try package.sha256
    initialState = config["initialState"] ?? .object([:])
    guard initialState.isValid else { throw CollaborationError("invalid_program", "Недопустимое начальное состояние.") }
    stagedText = text
    let versions = try files.map { file in
      let dots = DocumentFile.causalFieldKeys(id: file.id).map { key in
        document.collaboration?.fields[key]?.stamp ?? document.contentStamp
      }
      return JSONValue.object(["id": .string(file.id), "path": .string(file.path), "winningDots": try .encode(dots)])
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    sourceBasis = NotebookProgramPackage.hash(try encoder.encode(JSONValue.object([
      "path": .string(path), "package": .string(programPackage), "files": .array(versions)])))
  }

  /// Instances share the immutable accepted package and file basis; their
  /// state/runtime identity remains the authored instance ID.
  public func forInstance(_ instanceID: String) throws -> Self {
    guard !instanceID.isEmpty, instanceID.utf16.count <= 120 else {
      throw CollaborationError("invalid_program", "Программа требует ID экземпляра.")
    }
    return .init(id: instanceID, path: path, programPackage: programPackage,
      initialState: initialState, sourceBasis: sourceBasis, package: package, stagedText: stagedText)
  }
  private init(id: String, path: String, programPackage: String, initialState: JSONValue,
    sourceBasis: String, package: NotebookProgramPackage, stagedText: [String: Data]) {
    self.id = id; self.path = path; self.programPackage = programPackage; self.initialState = initialState
    self.sourceBasis = sourceBasis; self.package = package; self.stagedText = stagedText
  }

  static func configuration(_ file: DocumentFile?) throws -> (JSONValue, [String]) {
    let config: JSONValue
    if let file {
      guard file.isText else { throw CollaborationError("invalid_program", "program.json должен быть текстовым файлом.") }
      config = try JSONDecoder().decode(JSONValue.self, from: Data(file.source.utf8))
      guard case .object = config else { throw CollaborationError("invalid_program", "program.json содержит объект конфигурации.") }
    } else { config = .object([:]) }
    let dependencies = try config["dependencies"]?.decode([String].self) ?? []
    guard dependencies.allSatisfy(DocumentFile.validPath), Set(dependencies).count == dependencies.count else {
      throw CollaborationError("invalid_program", "Зависимости перечисляют относительные пути файлов документа.")
    }
    return (config, dependencies)
  }

}

extension NotebookStore {
  public func readDocumentFileBytes(_ file: DocumentFile) throws -> Data {
    guard file.isValid, file.byteCount <= DocumentDocument.maximumSourceBytes else {
      throw NotebookStorageError.limitExceeded("document_resource")
    }
    guard let descriptor = file.resource else { return Data(file.source.utf8) }
    var data = Data(), offset: Int64 = 0
    while offset < descriptor.byteCount {
      let part = try readProgramFile(descriptor, offset: offset, maxBytes: 1_048_576)
      data.append(part); offset += Int64(part.count)
    }
    return data
  }
  public func documentProgramSource(document: DocumentDocument, instanceID: String, path: String) throws -> DocumentProgramSource {
    var source = try DocumentProgramSource(document: document, instanceID: instanceID, path: path)
    return try commandTransaction {
      for (hash, bytes) in source.stagedText {
        guard try currentSQL!.putBlob(bytes) == hash else { throw NotebookStorageError.blobHashMismatch }
      }
      guard try stageProgramPackage(source.package) == source.programPackage else { throw NotebookStorageError.blobHashMismatch }
      source.stagedText.removeAll()
      return source
    }
  }
  public func documentProgramSource(documentID: UUID, instanceID: String, path: String) throws -> DocumentProgramSource {
    let document = try readTransaction { _ in try documentProgramProjection(documentID: documentID, programPath: path) }
    return try documentProgramSource(document: document, instanceID: instanceID, path: path)
  }
}
