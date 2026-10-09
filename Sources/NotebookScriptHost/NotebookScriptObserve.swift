import Foundation
import NotebookCore

extension NotebookScriptCoordinator {
  func observe(_ args: JSONValue) async throws -> JSONValue {
    if args["includeImage"] == .bool(true), args["target"] == nil, args["contextID"] == nil { await prepareCurrentView() }
    return try await reader { cut in
      let header = try cut.workspaceHeader(), presence = try cut.readObservedPresenceIfAvailable()
      let contextID = args.string("contextID").flatMap(UUID.init(uuidString:))
      if args["contextID"] != nil && contextID == nil {
        throw CollaborationError("invalid_reference", "Источник сообщения требует точный contextID.")
      }
      let currentSelection = args["target"] == nil && contextID == nil ? try cut.readSelectionPublication() : nil
      let selected = currentSelection?.status == "known" ? currentSelection?.selection : nil
      let selectedElement = [.element, .elements].contains(selected?.kind) ? selected : nil
      let target: CollaborationTarget?
      if let supplied = args["target"] { target = try supplied.decode(CollaborationTarget.self) }
      else if contextID != nil { target = nil }
      else if let selectedElement { target = selectedElement.target }
      else if let selected { target = selected.surface }
      else if presence?.mode == .page, let id = presence?.notebookPageID { target = .init(kind: .page, id: id) }
      else if presence?.mode == .document, let id = presence?.selectedItemID { target = .init(kind: .document, id: id) }
      else if let boardID = presence?.boardID { target = .init(kind: .board, id: boardID) }
      else { target = nil }
      let elementID = args.string("elementID"), fileID = args.string("fileID")
      guard (elementID == nil || target?.kind == .page), (fileID == nil || target?.kind == .document),
        args["ids"] == nil || (elementID == nil && fileID == nil) else {
        throw CollaborationError("invalid_reference", "elementID требует лист, fileID — файл документа; не смешивайте их с ids.")
      }
      let requestedLimit = args.number("limit") ?? 32
      guard (1...32).contains(requestedLimit), requestedLimit.rounded() == requestedLimit else {
        throw CollaborationError("resource_limit", "Страница наблюдения ограничена 1–32 элементами.")
      }
      var data: [String: JSONValue] = ["status": .string("context_unknown")]
      var coverage = NotebookReadCoverage(complete: true)
      if let target {
        let implicitID = selectedElement?.elementID
        let ids = try args["ids"]?.decode([String].self) ?? (elementID ?? fileID ?? implicitID).map { [$0] } ?? selectedElement?.elementIDs
        let defaults: [NotebookObservationScope.Field] = fileID != nil ? [.content, .version] : elementID != nil || implicitID != nil || selectedElement?.elementIDs != nil ? [.content, .geometry] : [.preview]
        let scope = NotebookObservationScope(target: target, ids: ids,
          fields: try args["fields"]?.decode([NotebookObservationScope.Field].self) ?? defaults,
          expand: try args["expand"]?.decode([NotebookObservationScope.Relation].self) ?? [],
          bounds: try args["bounds"]?.decode(NotebookReadBounds.self))
        if ids?.isEmpty != true {
          let observed = try cut.observeContent(scope:scope,since:args.string("since"),next:args.string("next"),limit:Int(requestedLimit))
          data = try JSONValue.encode(observed).fields
          data.removeValue(forKey:"coverage"); coverage = observed.coverage
        } else { data = ["mode":.string("snapshot"),"objects":.array([])] }
        data["target"] = try .encode(target)
        if let itemIDs = selected?.itemIDs {
          data["containers"] = try .encode(itemIDs.compactMap { try cut.readItemHeader($0) })
        }

      }
      if args["target"] == nil && contextID == nil {
        data["presence"] = try .encode(presence)
        data["presenceGeneration"] = .string(try cut.presenceGeneration())
        data["selection"] = try .encode(currentSelection)
      }
      if let contextID {
        if target == nil { data["status"] = .string("message_source") }
        data["context"] = try .encode(cut.sharedContexts(contextID: contextID, limit: 8))
      }
      var image: JSONValue = .object(["status": .string("not_requested")])
      if args["includeImage"] == .bool(true), contextID != nil {
        image = .object(["status": .string("source_reference_required")])
      } else if args["includeImage"] == .bool(true), args["target"] != nil {
        image = .object(["status": .string("target_render_required")])
      } else if args["includeImage"] == .bool(true), selected == nil {
        image = .object(["status": .string("current_scene_unknown")])
      } else if args["includeImage"] == .bool(true) {
        image = .object(["status": .string("pending")])
        if let receipt = try cut.loadCurrentViewReceipt(), receipt.workspaceStamp == header.stamp, receipt.presence == presence,
          receipt.boardRevision == header.boardRevision, receipt.spatialInkStamp == header.spatialInkStamp {
          let surface: CollaborationTarget
          let pageIndex: Int?
          switch receipt.surface {
          case .board(let id): surface = .init(kind: .board, id: id); pageIndex = nil
          case .cover(let id): surface = .init(kind: .cover, id: id, boardID: receipt.presence.boardID); pageIndex = nil
          case .page(_, let revision, _): surface = .init(kind: .page, id: revision.pageID); pageIndex = nil
          case .document(let revision, let index, _): surface = .init(kind: .document, id: revision.documentID); pageIndex = index
          }
          let fresh: Bool
          if selected?.surface != surface || selected?.pageIndex != pageIndex { fresh = false }
          else {
            switch receipt.surface {
            case .page(_, let revision, _):
              let metadata = try cut.readContentHeader(target: .init(kind: .page, id: revision.pageID))
              fresh = metadata.contentStamp == revision.agentStamp && metadata.inkStamp == revision.drawingStamp
            case .document(let revision, _, _):
              let metadata = try cut.readContentHeader(target: .init(kind: .document, id: revision.documentID))
              fresh = metadata.contentStamp == revision.contentStamp && metadata.stateStamp == revision.stateStamp
            default: fresh = true
            }
          }
          if fresh { image = .object(["status": .string("ready"), "receipt": try .encode(receipt),
            "artifact": try .encode(NotebookArtifactRequest(kind: .currentView, expectedSHA256: receipt.pngSHA256))]) }
        }
      }
      data["visual"] = image
      return try .encode(NotebookSnapshot(data: .object(data), basis: cut.readBasis(targets: target.map { [$0] } ?? []),
        coverage: coverage, cursor: String(cut.currentReadCursor())))
    }
  }
}
