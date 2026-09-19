import CryptoKit
import Foundation

/// Export bytes use the same immutable 4 MiB parts and 1 MiB read windows as
/// authored program resources. The extra digest names the complete flat file.
public struct NotebookExportFile: Codable, Equatable, Sendable {
  public let file: NotebookProgramPackage.File
  public let sha256: String
  public init(file: NotebookProgramPackage.File, sha256: String) { self.file = file; self.sha256 = sha256 }
  public func validate() throws {
    try file.validate()
    guard NotebookProgramPackage.validHash(sha256) else { throw NotebookStorageError.blobHashMismatch }
  }

  /// Describe a finished local file off the writer. Staging subsequently checks
  /// every part again, so an intervening edit can never publish different bytes.
  public static func inspect(_ url: URL, path: String) throws -> Self {
    let input = try NotebookProgramImport.openRegularFile(url); defer { try? input.close() }
    var whole = SHA256(), part = SHA256(), size: Int64 = 0, partSize = 0
    var parts: [NotebookProgramPackage.Part] = []
    while true {
      try Task.checkCancellation()
      let bytes = try input.read(upToCount: min(1_048_576, NotebookProgramPackage.partBytes-partSize)) ?? Data()
      if bytes.isEmpty { break }
      whole.update(data: bytes); part.update(data: bytes); size += Int64(bytes.count); partSize += bytes.count
      if partSize == NotebookProgramPackage.partBytes {
        parts.append(.init(sha256: hex(part.finalize()), byteCount: partSize)); part = SHA256(); partSize = 0
        guard parts.count <= 16_384 else { throw NotebookStorageError.limitExceeded("export parts") }
      }
    }
    if partSize > 0 { parts.append(.init(sha256: hex(part.finalize()), byteCount: partSize)) }
    let result = Self(file: .init(path: path, mimeType: NotebookProgramPackage.mimeType(for: path), byteCount: size, parts: parts),
      sha256: hex(whole.finalize()))
    try result.validate(); return result
  }
  fileprivate static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}

/// A native capability, not a Codable client-supplied path. Preparation streams
/// and verifies off the writer; only final admission belongs to its existing FIFO.
public final class NotebookPreparedExport: Sendable {
  fileprivate let root: URL
  fileprivate let staging: URL
  fileprivate let destination: URL
  fileprivate let publication: NotebookExportPublication
  public let receipt: NotebookExportReceipt
  fileprivate init(root: URL, staging: URL, destination: URL, publication: NotebookExportPublication, receipt: NotebookExportReceipt) {
    self.root = root; self.staging = staging; self.destination = destination; self.publication = publication; self.receipt = receipt
  }
  deinit { try? FileManager.default.removeItem(at: staging) }
}

extension NotebookStore {
  public func prepareDocumentExport(_ publication: NotebookExportPublication) throws -> NotebookPreparedExport {
    guard currentSQL == nil else { throw NotebookStorageError.invalidTransaction("Export preparation must precede SQL admission") }
    let cutData = try publication.cut.canonicalData(), assets = publication.assets
    let addressed = [publication.pdf] + assets + (publication.syncTeX.map { [$0] } ?? [])
    guard cutData.count <= 8*1024*1024, publication.source.utf8.count <= 4*1024*1024,
      publication.log.utf8.count <= 32_000, assets.count <= 128,
      publication.pdf.file.path == "document.pdf",
      assets.enumerated().allSatisfy({ $0.element.file.path == "notebook-image-\($0.offset).pdf" }),
      addressed.reduce(0, { $0 + $1.file.parts.count }) <= 16_384 else {
      throw CollaborationError("invalid_artifact", "Недопустимый печатный пакет.")
    }
    for file in addressed { try file.validate() }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard try encoder.encode(addressed).count <= NotebookProgramPackage.maximumManifestBytes else {
      throw CollaborationError("invalid_artifact", "Описание экспортных файлов превышает 1 МиБ.")
    }
    var metadata = [("document.cut.json", cutData), ("document.tex", Data(publication.source.utf8))]
    if let map = publication.sourceMap, let syncTeX = publication.syncTeX {
      guard syncTeX.file.path == "document.synctex.gz" else { throw CollaborationError("invalid_artifact", "Неверный адрес карты страниц.") }
      try map.validate(document: publication.cut.document, source: publication.source, pdfSHA256: publication.pdf.sha256)
      let encoded = try encoder.encode(map)
      guard encoded.count <= 1_048_576 else { throw CollaborationError("invalid_artifact", "Карта блоков превышает 1 МиБ.") }
      metadata.append(("document.source-map.json", encoded))
    } else if publication.sourceMap != nil || publication.syncTeX != nil {
      throw CollaborationError("invalid_artifact", "Карта блоков и карта страниц публикуются вместе.")
    }
    let directory = root.appendingPathComponent("exports", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let staging = directory.appendingPathComponent(".pending-" + UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      var files: [(name: String, size: Int64, hash: String, mime: String)] = []
      for (name, data) in metadata {
        try Task.checkCancellation()
        try data.write(to: staging.appendingPathComponent(name))
        files.append((name, Int64(data.count), NotebookExportFile.hex(SHA256.hash(data: data)), NotebookProgramPackage.mimeType(for: name)))
      }
      for item in addressed {
        let url = staging.appendingPathComponent(item.file.path)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
          throw CollaborationError("invalid_artifact", "Не удалось подготовить файл экспорта.")
        }
        let output = try FileHandle(forWritingTo: url); defer { try? output.close() }
        var offset: Int64 = 0, digest = SHA256()
        while offset < item.file.byteCount {
          try Task.checkCancellation()
          let bytes = try readProgramFile(item.file, offset: offset, maxBytes: 1_048_576)
          guard !bytes.isEmpty else { throw NotebookStorageError.blobHashMismatch }
          if offset == 0 {
            let prefix = item.file.mimeType == "application/pdf" ? Data("%PDF-".utf8) : Data([0x1f, 0x8b])
            guard bytes.starts(with: prefix) else { throw CollaborationError("invalid_artifact", "Файл не соответствует формату экспорта.") }
          }
          digest.update(data: bytes); try output.write(contentsOf: bytes); offset += Int64(bytes.count)
        }
        guard offset > 0, NotebookExportFile.hex(digest.finalize()) == item.sha256 else { throw NotebookStorageError.blobHashMismatch }
        try output.close()
        files.append((item.file.path, offset, item.sha256, item.file.mimeType))
      }
      // Sorted length-framed names, sizes and content hashes bind every file.
      var digest = SHA256()
      for file in files.sorted(by: { $0.name < $1.name }) {
        let name = Data(file.name.utf8)
        for number in [UInt64(name.count), UInt64(file.size)] {
          var value = number.bigEndian; withUnsafeBytes(of: &value) { digest.update(data: Data($0)) }
        }
        digest.update(data: name); digest.update(data: Data(file.hash.utf8))
      }
      let hash = NotebookExportFile.hex(digest.finalize())
      let destination = directory.appendingPathComponent(publication.documentID.uuidString.lowercased() + "-" + hash, isDirectory: true)
      if FileManager.default.fileExists(atPath: destination.path) {
        for file in files {
          let existing = try NotebookExportFile.inspect(destination.appendingPathComponent(file.name), path: file.name)
          guard existing.sha256 == file.hash, existing.file.byteCount == file.size else { throw NotebookStorageError.blobHashMismatch }
        }
      }
      func artifact(_ name: String) -> NotebookArtifact? {
        files.first { $0.name == name }.map { .init(path: destination.appendingPathComponent(name).path,
          sha256: $0.hash, byteCount: Int($0.size), mimeType: $0.mime) }
      }
      let cut = artifact("document.cut.json")!
      let receipt = NotebookExportReceipt(cutSHA256: cut.sha256, stateRevision: publication.cut.state.stamp.revision,
        cut: cut, documentID: publication.documentID, texPath: destination.appendingPathComponent("document.tex").path,
        pdfPath: destination.appendingPathComponent("document.pdf").path, pdfSHA256: publication.pdf.sha256,
        byteCount: Int(publication.pdf.file.byteCount), log: publication.log, packageSHA256: hash,
        assets: assets.compactMap { artifact($0.file.path) }, sourceMap: artifact("document.source-map.json"), syncTeX: artifact("document.synctex.gz"))
      try Task.checkCancellation()
      return NotebookPreparedExport(root: root, staging: staging, destination: destination, publication: publication, receipt: receipt)
    } catch { try? FileManager.default.removeItem(at: staging); throw error }
  }

  public func publishDocumentExport(_ prepared: NotebookPreparedExport) throws -> NotebookExportReceipt {
    guard prepared.root == root else { throw NotebookStorageError.invalidTransaction("export owner") }
    let publication = prepared.publication
    return try commandTransaction(advancesReadRevision: false, readAllowance: .agentCommand) {
      if let id = publication.jobID, let saved = try scriptExportJob(id), saved["status"] == .string("saved"),
        let receipt = saved["receipt"] { return try receipt.decode(NotebookExportReceipt.self) }
      if let id = publication.jobID, try scriptExportJob(id)?["status"]?.string == "cancelled" { throw CancellationError() }
      guard try loadDocument(publication.documentID) == publication.cut.document,
        try loadDocumentState(publication.documentID) == publication.cut.state else {
        throw CollaborationError("revision_conflict", "Исходник или состояние изменились во время экспорта.")
      }
      if !FileManager.default.fileExists(atPath: prepared.destination.path) {
        try FileManager.default.moveItem(at: prepared.staging, to: prepared.destination)
      }
      let receipt = prepared.receipt
      if let id = publication.jobID {
        try saveScriptExportJob(id, value: .object(["status": .string("saved"), "jobID": .string(id.uuidString.lowercased()),
          "contentRevision": .string(publication.expectedRevision), "stateRevision": .string(publication.cut.state.stamp.revision),
          "cutSHA256": .string(receipt.cutSHA256), "moment": .string("saved"), "receipt": try .encode(receipt)]))
      }
      return receipt
    }
  }
}
