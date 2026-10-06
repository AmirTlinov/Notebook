import CryptoKit
import Foundation
import NotebookCore

/// Native fixtures exercise the same immutable preparation and command as the
/// picker. Test-owned bytes leave through a temporary local file capability.
enum NotebookPortableImportFixture {
  static func prepare(_ data: Data, targetBoardID: UUID, actor: UUID) throws -> NotebookPortableDocumentImport.Prepared {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("portable-native-fixture-" + UUID().uuidString + ".notex")
    try data.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let inspection = try NotebookPortableDocumentImport.inspect(file: file, expectedHash: hash)
    let sources = try inspection.readMetadata().decode().readSources()
    return try sources.prepare(requestID: UUID(), targetBoardID: targetBoardID, center: .zero, actor: actor)
  }
}
