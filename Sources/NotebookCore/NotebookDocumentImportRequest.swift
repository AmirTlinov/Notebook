import Foundation

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
  public func validate() throws {
    guard filePath.hasPrefix("/"), !filePath.contains("\0"), filePath.utf8.count <= 4096,
      NotebookProgramPackage.validHash(sha256), center.isValid else { throw Self.invalid() }
  }
  private static func invalid() -> CollaborationError { .init("invalid_document_import", "Нужен выбранный локальный файл документа и точное место импорта.") }
}
