import Foundation
import NotebookCore

extension NotebookScriptCoordinator {
  func observe(_ args: JSONValue) async throws -> JSONValue {
    try await persistence { store in
      try store.readTransaction { _ in
        let header = try store.workspaceHeader(), presence = try store.readPresenceIfAvailable()
        let shared = try store.sharedContexts(contextID: args.string("contextID").flatMap(UUID.init(uuidString:)), limit: 8)
        let target: CollaborationTarget?
        if let supplied = args["target"] { target = try supplied.decode(CollaborationTarget.self) }
        else if presence?.mode == .page, let id = presence?.notebookPageID { target = .init(kind: .page, id: id) }
        else if presence?.mode == .document, let id = presence?.selectedItemID { target = .init(kind: .document, id: id) }
        else { target = nil }
        let elementID = args.string("elementID"), blockID = args.string("blockID")
        guard (elementID == nil || target?.kind == .page), (blockID == nil || target?.kind == .document) else {
          throw CollaborationError("invalid_reference", "elementID требует лист, blockID — документ.")
        }
        let requestedLimit = args.number("limit") ?? 32
        guard (1...32).contains(requestedLimit), requestedLimit.rounded() == requestedLimit else {
          throw CollaborationError("resource_limit", "Превью ограничено 1–32 элементами.")
        }
        var keys: [String: JSONValue] = ["workspace": .string(header.stamp.revision),
          "board": .string(try store.targetContentRevision(target: .init(kind: .board, id: presence?.boardID ?? header.rootBoardID))),
          "spatialInk": header.spatialInkStamp.map { .string($0.revision) } ?? .null, "contexts": .string(shared.readCursor),
          "view": try .encode(presence), "scope": .object(["target": try .encode(target),
            "elementID": elementID.map(JSONValue.string) ?? .null, "blockID": blockID.map(JSONValue.string) ?? .null,
            "limit": .number(requestedLimit)])]
        let previous = args["since"]?.fields ?? [:]
        var content: JSONValue = presence.map { .object(["kind": .string($0.mode.rawValue), "boardID": .string($0.boardID.uuidString.lowercased())]) }
          ?? .object(["status": .string("context_unknown")])
        if let target {
          let metadata = try store.readContentHeader(target: target)
          let prefix = "\(target.kind.rawValue):\(target.id)"
          keys[prefix + ":content"] = .string(metadata.contentStamp.revision)
          if let ink = metadata.inkStamp { keys[prefix + ":ink"] = .string(ink.revision) }
          if let state = metadata.stateStamp { keys[prefix + ":state"] = .string(state.revision) }
          var fields: [String: JSONValue] = ["kind": .string(target.kind.rawValue), "id": .string(target.id.uuidString.lowercased())]
          fields[target.kind == .page ? "agentRevision" : "contentRevision"] = .string(metadata.contentStamp.revision)
          fields["drawingRevision"] = metadata.inkStamp.map { .string($0.revision) }
          fields["stateRevision"] = metadata.stateStamp.map { .string($0.revision) }
          let unchanged = previous["scope"] == keys["scope"] && keys.keys.filter { $0.hasPrefix(prefix + ":") }.allSatisfy { previous[$0] == keys[$0] }
          if unchanged { fields["unchanged"] = .bool(true) }
          else if let elementID {
            let element = try store.readPageElementSnapshot(pageID: target.id, elementID: elementID)
            fields["element"] = try .encode(element?.element)
            fields["graphicResolution"] = element?.graphicResolution
          } else if let blockID {
            fields["block"] = try .encode(store.readDocumentBlock(documentID: target.id, blockID: blockID))
          } else {
            let preview = try store.readContentPreviews(target: target, limit: Int(requestedLimit))
            fields[target.kind == .page ? "elements" : "blocks"] = try .encode(preview.items)
            fields["truncated"] = .bool(!preview.complete)
          }
          content = .object(fields)
        }
        let changes: JSONValue = .object(["changed": .array(keys.keys.sorted().filter { previous[$0] != keys[$0] }.map(JSONValue.string)),
          "removed": .array(previous.keys.sorted().filter { keys[$0] == nil }.map(JSONValue.string))])
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
        return .object(["status": .string("ready"), "header": try .encode(header), "presence": try .encode(presence),
          "contexts": try .encode(shared), "connection": try .encode(store.loadRuntimeStatus()), "content": content,
          "cursor": .string(String(try store.currentReadCursor())), "changeKeys": .object(keys), "changes": changes, "visual": image])
      }
    }
  }
}
