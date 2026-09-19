import Foundation
import NotebookCore
import NotebookScriptProtocol

extension NotebookScriptCoordinator {
  func startExport(id: UUID, arguments: JSONValue) async throws -> JSONValue {
    if let previous = try await persistence({ try $0.scriptExportJob(id) ?? .null }).optionalValue { return previous }
    guard exportTasks.count + exportAdmissions < 2, let documentID = arguments.string("documentID").flatMap(UUID.init(uuidString:)) else {
      throw CollaborationError("export_limit", "Нужен documentID; на Mac одновременно собираются до двух PDF.")
    }
    exportAdmissions += 1
    defer { exportAdmissions -= 1 }
    let cut = try await persistence { store in try store.readTransaction {
      try .encode(NotebookExportCut(document: $0.loadDocument(documentID), state: $0.loadDocumentState(documentID)))
    } }.decode(NotebookExportCut.self)
    let document = cut.document, cutHash = try cut.sha256
    let accepted = JSONValue.object(["status": .string("queued"), "jobID": .string(id.uuidString.lowercased()),
      "documentID": .string(documentID.uuidString.lowercased()), "contentRevision": .string(document.contentStamp.revision),
      "stateRevision": .string(cut.state.stamp.revision), "cutSHA256": .string(cutHash), "moment": .string("saved")])
    _ = try await persistence { try $0.saveScriptExportJob(id, value: accepted); return .null }
    exportTasks[id] = Task { [self] in
      do {
        var running = accepted.fields; running["status"] = .string("running")
        let started = JSONValue.object(running)
        _ = try await persistence { try $0.saveScriptExportJob(id, value: started); return .null }
        let publication = try await canonicalExport(cut, id)
        guard publication.cut == cut, publication.jobID == id else {
          throw CollaborationError("invalid_export_cut", "Renderer вернул другой срез или задание.")
        }
        let receipt = try await send(["command": .string("publishExport"), "export": try .encode(publication)])
        let saved = JSONValue.object(["status": .string("saved"), "jobID": .string(id.uuidString.lowercased()),
          "contentRevision": .string(document.contentStamp.revision), "stateRevision": .string(cut.state.stamp.revision),
          "cutSHA256": .string(cutHash), "moment": .string("saved"), "receipt": receipt])
        _ = try await persistence { try $0.saveScriptExportJob(id, value: saved); return .null }
      } catch {
        var fields = accepted.fields; fields["status"] = .string("failed"); fields["error"] = Self.error(error)
        let failure = JSONValue.object(fields)
        _ = try? await persistence { try $0.saveScriptExportJob(id, value: failure); return .null }
      }
      exportTasks.removeValue(forKey: id)
    }
    return accepted
  }
}

