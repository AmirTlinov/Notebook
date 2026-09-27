import Foundation
import NotebookCore
import NotebookTypesetter

@MainActor
enum NotebookDocumentImportOwner {
  struct Result {
    let documentID: UUID
    let actionID: UUID
    let cachedPrint: Bool
    var response: JSONValue {
      .object(["status": .string("imported"), "documentID": .string(documentID.uuidString.lowercased()),
        "actionID": .string(actionID.uuidString.lowercased()), "cachedPrint": .bool(cachedPrint)])
    }
  }
  static func run(_ request: NotebookDocumentImportRequest, persistence: NotebookPersistenceQueue, actor: UUID) async throws -> Result {
    let data = try await Task.detached { try request.readData() }.value
    let revision = try? await DocumentCanonicalPrint.store.compilerRevision()
    let imported = try await persistence.submit(publishesChanges: true) { store in
      try store.importPortableDocument(data: data, targetBoardID: request.targetBoardID, center: request.center,
        actor: actor, compilerRevision: revision, requestID: request.id)
    }
    var cached = false
    if let derived = imported.derived {
      do {
        let (document, input) = try await persistence.submit { store in
          let document = try store.loadDocument(imported.documentID)
          return (document, try NotebookTypesetterInput(document: document) { try store.readDocumentFileBytes($0) })
        }
        try await DocumentCanonicalPrint.store.adopt(derived, for: document, input: input)
        cached = true
      } catch { /* Optional print cache cannot roll back the saved source. */ }
    }
    return .init(documentID: imported.documentID, actionID: imported.receipt.id, cachedPrint: cached)
  }
}
