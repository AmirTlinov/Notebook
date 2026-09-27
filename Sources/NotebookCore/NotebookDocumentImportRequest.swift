import Foundation
import CryptoKit

/// A local file capability. It never enters authored content or a program's
/// namespace; retries carry the same id and digest through the native owner.
public struct NotebookDocumentImportRequest: Codable, Sendable {
  public let id: UUID
  public let filePath: String
  public let sha256: String
  public let targetBoardID: UUID
  public let center: WorldPoint
  public init(id: UUID = UUID(), filePath: String, sha256: String, targetBoardID: UUID, center: WorldPoint) {
    self.id = id; self.filePath = filePath; self.sha256 = sha256; self.targetBoardID = targetBoardID; self.center = center
  }
  public static func inspect(_ url: URL, targetBoardID: UUID, center: WorldPoint) throws -> Self {
    guard url.isFileURL, center.isValid else { throw invalid() }
    let bytes = try read(url)
    return .init(filePath: url.path, sha256: hash(bytes), targetBoardID: targetBoardID, center: center)
  }
  public func readData() throws -> Data {
    guard filePath.hasPrefix("/"), !filePath.contains("\0"), filePath.utf8.count <= 4096,
      NotebookProgramPackage.validHash(sha256), center.isValid else { throw Self.invalid() }
    let data = try Self.read(URL(fileURLWithPath: filePath))
    guard Self.hash(data) == sha256 else { throw CollaborationError("source_changed", "Файл импорта изменился после выбора.") }
    return data
  }
  private static func read(_ url: URL) throws -> Data {
    let handle = try NotebookProgramImport.openRegularFile(url); defer { try? handle.close() }
    let data = try handle.read(upToCount: 64*1024*1024+1) ?? Data()
    guard !data.isEmpty, data.count <= 64*1024*1024 else { throw CollaborationError("resource_limit", "Документ должен занимать не более 64 МиБ.") }
    return data
  }
  private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  private static func invalid() -> CollaborationError { .init("invalid_document_import", "Нужен выбранный локальный файл документа и точное место импорта.") }
}
