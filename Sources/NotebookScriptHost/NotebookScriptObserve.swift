import Foundation
import NotebookCore

extension NotebookScriptCoordinator {
  func observe(_ args: JSONValue) async throws -> JSONValue {
    try await persistence { store in
      try store.readTransaction { _ in
        let header = try store.workspaceHeader(), presence = try store.readPresenceIfAvailable()
        let target: CollaborationTarget?
        if let supplied = args["target"] { target = try supplied.decode(CollaborationTarget.self) }
        else if presence?.mode == .page, let id = presence?.notebookPageID { target = .init(kind: .page, id: id) }
        else if presence?.mode == .document, let id = presence?.selectedItemID { target = .init(kind: .document, id: id) }
        else if let boardID = presence?.boardID { target = .init(kind: .board, id: boardID) }
        else { target = nil }
        let elementID = args.string("elementID"), blockID = args.string("blockID")
        guard (elementID == nil || target?.kind == .page), (blockID == nil || target?.kind == .document),
          args["ids"] == nil || (elementID == nil && blockID == nil) else {
          throw CollaborationError("invalid_reference", "elementID требует лист, blockID — документ; не смешивайте их с ids.")
        }
        let requestedLimit = args.number("limit") ?? 32
        guard (1...32).contains(requestedLimit), requestedLimit.rounded() == requestedLimit else {
          throw CollaborationError("resource_limit", "Страница наблюдения ограничена 1–32 элементами.")
        }
        var data: [String: JSONValue] = ["status": .string("context_unknown")]
        var coverage = NotebookReadCoverage(complete: true)
        if let target {
          let ids = try args["ids"]?.decode([String].self) ?? (elementID ?? blockID).map { [$0] }
          let defaults: [NotebookObservationScope.Field] = blockID != nil ? [.content, .state] : elementID != nil ? [.content, .geometry] : [.preview]
          let scope = NotebookObservationScope(target: target, ids: ids,
            fields: try args["fields"]?.decode([NotebookObservationScope.Field].self) ?? defaults,
            expand: try args["expand"]?.decode([NotebookObservationScope.Relation].self) ?? [],
            bounds: try args["bounds"]?.decode(NotebookReadBounds.self))
          let observed = try store.observeContent(scope: scope, since: args.string("since"), next: args.string("next"), limit: Int(requestedLimit))
          data = try JSONValue.encode(observed).fields
          data.removeValue(forKey: "coverage")
          data["target"] = try .encode(target)
          coverage = observed.coverage
        }
        if args["target"] == nil {
          data["presence"] = try .encode(presence)
          data["presenceGeneration"] = .string(try store.presenceGeneration())
        }
        if let contextID = args.string("contextID").flatMap(UUID.init(uuidString:)) {
          data["context"] = try .encode(store.sharedContexts(contextID: contextID, limit: 8))
        }
        var image: JSONValue = .object(["status": .string("not_requested")])
        if args["includeImage"] == .bool(true) {
          image = .object(["status": .string("pending")])
          if let receipt = try store.loadCurrentViewReceipt(), receipt.workspaceStamp == header.stamp, receipt.presence == presence,
            receipt.boardRevision == header.boardRevision, receipt.spatialInkStamp == header.spatialInkStamp {
            let fresh: Bool
            switch receipt.surface {
            case .page(_, let revision, _):
              let metadata = try store.readContentHeader(target: .init(kind: .page, id: revision.pageID))
              fresh = metadata.contentStamp == revision.agentStamp && metadata.inkStamp == revision.drawingStamp
            case .document(let revision, _, _):
              let metadata = try store.readContentHeader(target: .init(kind: .document, id: revision.documentID))
              fresh = metadata.contentStamp == revision.contentStamp && metadata.stateStamp == revision.stateStamp
            default: fresh = true
            }
            if fresh { image = .object(["status": .string("ready"), "receipt": try .encode(receipt),
              "artifact": try .encode(NotebookArtifactRequest(kind: .currentView, expectedSHA256: receipt.pngSHA256))]) }
          }
        }
        data["visual"] = image
        return try .encode(NotebookSnapshot(data: .object(data), basis: store.readBasis(targets: target.map { [$0] } ?? []),
          coverage: coverage, cursor: String(store.currentReadCursor())))
      }
    }
  }
}
