import Foundation

/// A transport envelope around existing documents and V2 packages, not another
/// authoring model. The directory stores each addressed part exactly once.
public struct NotebookPortableDocument: Codable, Sendable {
  public let format: String
  public let cut: NotebookExportCut
  public let packages: [Package]
  public struct Package: Codable, Sendable {
    public let sha256: String
    public let value: NotebookProgramPackage
    public init(sha256: String, value: NotebookProgramPackage) { self.sha256 = sha256; self.value = value }
  }
  public init(cut: NotebookExportCut, packages: [Package]) {
    format = "NotebookPortable/1"; self.cut = cut; self.packages = packages.sorted { $0.sha256 < $1.sha256 }
  }
  public func blobs() throws -> [NotebookExportFile] {
    guard format == "NotebookPortable/1", packages.count <= 512,
      Set(packages.map(\.sha256)).count == packages.count,
      Set(packages.map(\.sha256)) == Set(cut.document.blocks.compactMap(\.programPackage)) else {
      throw CollaborationError("invalid_portable_document", "Пакеты должны точно соответствовать исходнику документа.")
    }
    _ = try cut.canonicalData()
    var parts: [String: NotebookProgramPackage.Part] = [:]
    for package in packages {
      guard try package.value.sha256 == package.sha256 else { throw NotebookStorageError.blobHashMismatch }
      for part in package.value.files.flatMap(\.parts) {
        if let previous = parts[part.sha256], previous.byteCount != part.byteCount { throw NotebookStorageError.blobHashMismatch }
        parts[part.sha256] = part
      }
    }
    guard parts.count <= 16_383 else { throw NotebookStorageError.limitExceeded("portable document parts") }
    return parts.values.sorted { $0.sha256 < $1.sha256 }.map {
      .init(file: .init(path: "blob-" + $0.sha256, mimeType: "application/octet-stream", byteCount: Int64($0.byteCount), parts: [$0]), sha256: $0.sha256)
    }
  }
  public func data() throws -> Data {
    _ = try blobs()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(self)
    guard data.count <= 8*1024*1024 else { throw NotebookStorageError.limitExceeded("portable document metadata") }
    return data
  }
}
