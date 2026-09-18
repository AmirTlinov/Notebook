import Foundation
import NotebookCore
import NotebookScriptProtocol

extension NotebookScriptCoordinator {
  func startExport(id: UUID, arguments: JSONValue) async throws -> JSONValue {
    if let previous = try await persistence({ try $0.scriptExportJob(id) ?? .null }).optionalValue { return previous }
    guard exportTasks.count < 2, let documentID = arguments.string("documentID").flatMap(UUID.init(uuidString:)) else {
      throw CollaborationError("export_limit", "Нужен documentID; на Mac одновременно собираются до двух PDF.")
    }
    let document = try await persistence { try .encode($0.loadDocument(documentID)) }.decode(DocumentDocument.self)
    let accepted = JSONValue.object(["status": .string("queued"), "jobID": .string(id.uuidString.lowercased()),
      "documentID": .string(documentID.uuidString.lowercased()), "contentRevision": .string(document.contentStamp.revision)])
    _ = try await persistence { try $0.saveScriptExportJob(id, value: accepted); return .null }
    exportTasks[id] = Task { [self] in
      do {
        var running = accepted.fields; running["status"] = .string("running")
        let started = JSONValue.object(running)
        _ = try await persistence { try $0.saveScriptExportJob(id, value: started); return .null }
        let result = try await markup.normalize(.object(["kind": .string("documentTeX"), "document": try .encode(document)]))
        guard let source = result.string("source") else { throw CollaborationError("normalization_failed", "Нет печатного исходника.") }
        let assets = try (result["assets"] ?? .array([])).decode([NotebookCompilerAsset].self)
        let ranges = try (result["sourceRanges"] ?? .null).decode([DocumentPrintSourceRange].self)
        let compiled = try await markup.compile(id: id, source: source, assets: assets)
        let sourceMap = try DocumentPrintSourceMap(document: document, source: source, pdf: compiled.pdf, ranges: ranges)
        let publication = NotebookExportPublication(documentID: document.id, expectedRevision: document.contentStamp.revision,
          source: source, pdf: compiled.pdf, log: compiled.log, jobID: id,
          assets: compiled.assets.map { .init(name: $0.name, data: $0.data) }, sourceMap: sourceMap, syncTeX: compiled.syncTeX)
        let receipt = try await send(["command": .string("publishExport"), "export": try .encode(publication)])
        let saved = JSONValue.object(["status": .string("saved"), "jobID": .string(id.uuidString.lowercased()),
          "contentRevision": .string(document.contentStamp.revision), "receipt": receipt])
        _ = try await persistence { try $0.saveScriptExportJob(id, value: saved); return .null }
      } catch {
        let failure = JSONValue.object(["status": .string("failed"), "jobID": .string(id.uuidString.lowercased()), "error": Self.error(error)])
        _ = try? await persistence { try $0.saveScriptExportJob(id, value: failure); return .null }
      }
      exportTasks.removeValue(forKey: id)
    }
    return accepted
  }
}

