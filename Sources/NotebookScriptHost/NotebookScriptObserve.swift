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
        var keys: [String: JSONValue] = ["workspace": .string(header.stamp.revision),
          "board": .string(try store.targetContentRevision(target: .init(kind: .board, id: presence?.boardID ?? header.rootBoardID))),
          "spatialInk": header.spatialInkStamp.map { .string($0.revision) } ?? .null, "contexts": .string(shared.readCursor),
          "presenceGeneration": .string(try store.presenceGeneration())]
        let previous = args["since"]?.fields ?? [:]
        var content: JSONValue = .object(["status": .string("context_unknown")])
        if let target {
          let ids = try args["ids"]?.decode([String].self) ?? (elementID ?? blockID).map { [$0] }
          let defaults: [NotebookObservationScope.Field] = blockID != nil ? [.content, .state] : elementID != nil ? [.content, .geometry] : [.preview]
          let scope = NotebookObservationScope(target: target, ids: ids,
            fields: try args["fields"]?.decode([NotebookObservationScope.Field].self) ?? defaults,
            expand: try args["expand"]?.decode([NotebookObservationScope.Relation].self) ?? [],
            bounds: try args["bounds"]?.decode(NotebookReadBounds.self))
          if args["since"] != nil, previous["checkpoint"] == nil {
            throw CollaborationError("observation_incomplete", "Сначала дочитайте coverage.next; только полное наблюдение даёт checkpoint.")
          }
          let observed = try store.observeContent(scope: scope, since: args["since"]?.string("checkpoint"),
            next: args.string("next"), limit: Int(requestedLimit))
          keys["scope"] = try .encode(scope)
          keys["checkpoint"] = observed.checkpoint.map(JSONValue.string)
          var value = try JSONValue.encode(observed).fields
          value["kind"] = .string(target.kind.rawValue); value["id"] = .string(target.id.uuidString.lowercased())
          value["unchanged"] = .bool(observed.mode == "delta" && observed.objects.isEmpty)
          value["truncated"] = .bool(!observed.coverage.complete)
          if let stamp = try observed.header["contentStamp"]?.decode(VersionStamp.self) {
            value[target.kind == .page ? "agentRevision" : "contentRevision"] = .string(stamp.revision)
          }
          if let stamp = try observed.header["inkStamp"]?.decode(VersionStamp.self) { value["drawingRevision"] = .string(stamp.revision) }
          if let stamp = try observed.header["stateStamp"]?.decode(VersionStamp.self) { value["stateRevision"] = .string(stamp.revision) }
          if let elementID {
            let object = observed.objects.first { $0.id == elementID }
            value["element"] = object?.value?["content"] ?? (object == nil ? nil : .null)
            value["graphicResolution"] = object?.value?["graphicResolution"]
          } else if let blockID {
            if let object = observed.objects.first(where: { $0.id == blockID }), let body = object.value?["content"] {
              var block = object.value!.fields
              block.removeValue(forKey: "content"); block["block"] = body
              block["documentID"] = .string(target.id.uuidString.lowercased())
              block["contentStamp"] = observed.header["contentStamp"]; block["stateStamp"] = observed.header["stateStamp"]
              value["block"] = .object(block)
            }
          } else {
            value[target.kind == .document ? "blocks" : "elements"] = .array(observed.objects.filter { $0.change == .upsert }.map {
              var preview = $0.value?.fields ?? [:]; preview["id"] = .string($0.id); return .object(preview)
            })
          }
          content = .object(value)
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
          "cursor": .string(String(try store.currentReadCursor())), "presenceGeneration": .string(try store.presenceGeneration()), "changeKeys": .object(keys), "changes": changes, "visual": image])
      }
    }
  }
}
