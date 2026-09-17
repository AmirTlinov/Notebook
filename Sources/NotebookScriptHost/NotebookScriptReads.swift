import Foundation
import CryptoKit
import NotebookCore

enum NotebookScriptAPI {
  static let readMethods: Set<String> = ["help", "observe", "read", "readMany", "board", "notebook", "page", "document",
    "context", "attention", "code", "search", "reference", "referenceStatus", "action", "render", "pageMap",
    "pageImage", "regions", "place", "exportStatus", "presentation", "wait"]
  static var help: JSONValue { .object([
    "status": .string("ready"), "api_version": .number(1), "language": .string("ECMAScript / QuickJS 2026-06-04"),
    "limits": .object(["active_runs": .number(1), "queued_runs": .number(8), "source_bytes": .number(262144),
      "arguments_bytes": .number(1048576), "heap_bytes": .number(134217728), "stack_bytes": .number(1048576),
      "cpu_seconds": .number(5), "wall_seconds": .number(30), "tool_reply_seconds": .number(4), "outstanding_calls": .number(4),
      "host_calls": .number(1024), "effects": .number(128), "output_bytes": .number(4194304),
      "output_event_bytes": .number(262144), "result_bytes": .number(262144), "output_page_bytes": .number(1048576)]),
    "reads": .array(readMethods.sorted().map(JSONValue.string)),
    "effects": .array(["transaction(key, action)", "undo(key, {actionID})", "point(key, {references, contextID?, replyTo?})",
      "present(key, {view, steps})", "cancelPresentation(key, {id})", "export(key, {documentID})"].map(JSONValue.string)),
    "utilities": .array(["await nb.id(key)", "await emit(value)", "await emitImage(artifact)", "await nb.wait({milliseconds:100})"].map(JSONValue.string)),
    "read_contract": .string("read({kind,...}) returns one native owner and cursor; readMany({queries,expectedCursor?}) returns one bounded snapshot. IDs, revisions and continuation cursors come from owners, never inferred from omitted data."),
    "execution_contract": .string("Async JavaScript with args and nb only. No Node, Python, DOM, require, fetch, filesystem, network, module loader, SQLite or user bytecode. Same run_id+code+args attaches. Changed payload conflicts. Resume never replays source or restores a JS heap. Mac owns the 30s active-run wall deadline, including XPC sandbox launch; script_timeout does not depend on a worker reply."),
    "reply_deadline": .string("One MCP reply has four seconds total, including owner admission and images. response_pending includes run_id, original after_seq and admission unknown/confirmed. It never cancels an accepted write. Resume that ID and cursor. If run_missing with after_seq:0, retry the identical start, never a fresh ID. wait_ms is an upper bound from native handler entry, not after admission; the adapter shortens it to leave room for IPC response."),
    "mutation_contract": .string("Every effect requires a stable key. One transaction is atomic and undoable; a whole program may save several effects. Cancellation prevents new effects and reports accepted native outcomes. Native undo preserves later human edits."),
    "images": .string("Image reads return opaque descriptors with exact hashes. emitImage freezes exact pixels in the native output journal; image bytes count toward 4 MiB per run. Up to four image events per resume page. JavaScript receives no file capability."),
    "exports": .string("export starts a persisted native job; retain jobID and read exportStatus after JS ends. Two slots, 120 seconds each. The markup App Sandbox runs pinned Tectonic 0.16.9 with the complete offline TeX distribution, no user cache/files or network. TeX source <=4 MiB, PDF <=16 MiB, temporary files <=128 MiB, process memory <=1 GiB."),
    "old_receipts": .string("Existing action and undo receipts stay readable. A raw retry without an original fingerprint fails request_identity_unavailable."),
  ]) }
  static func documentation(_ topic: String?) throws -> JSONValue {
    guard let url = Bundle.module.url(forResource: "sdk-reference", withExtension: "json") else {
      throw CollaborationError("sdk_contract_missing", "Сборка не содержит справочник SDK.")
    }
    let reference = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    guard let topic else {
      var value = help.fields
      value["topics"] = .array((reference["methods"]?.fields.keys.sorted() ?? []).map(JSONValue.string)
        + ["operations", "examples", "interactive", "execution"].map(JSONValue.string))
      value["run_completion"] = reference["execution"]?["polling"]
      value["help"] = .string("Call nb.help(topic) or notebook_context(method:'help',args:{topic}). operations is a compact index; operation/<name> gives one exact schema. interactive includes notebook.ready(promise); execution explains terminal status and output pagination.")
      return .object(value)
    }
    let value: JSONValue?
    if topic.hasPrefix("operation/") {
      value = reference["operationDetails"]?[String(topic.dropFirst("operation/".count))]
    } else if ["operations", "examples", "interactive", "execution"].contains(topic) {
      value = reference[topic]
    } else {
      value = reference["methods"]?[topic]
    }
    guard let value else {
      throw CollaborationError("unknown_help_topic", "Выберите тему из справочника SDK.")
    }
    return .object(["api_version": .number(1), "topic": .string(topic), "contract": value])
  }
}

extension NotebookScriptCoordinator {
  func send(_ fields: [String: JSONValue]) async throws -> JSONValue {
    try await command(NotebookIPC.decodeCommand(JSONEncoder().encode(JSONValue.object(fields))))
  }

  func nativeRead(_ queries: [JSONValue], cursor: String? = nil) async throws -> JSONValue {
    var request: [String: JSONValue] = ["command": .string("read"), "queries": .array(queries)]
    if let cursor { request["expectedCursor"] = .string(cursor) }
    return try await send(request)
  }

  func read(method: String, arguments args: JSONValue) async throws -> JSONValue {
    guard case .object = args else { throw CollaborationError("invalid_arguments", "Метод SDK получает объект аргументов из nb.help(method).") }
    switch method {
    case "help": return try NotebookScriptAPI.documentation(args.string("topic"))
    case "read": return try await nativeRead([args])
    case "readMany": return try await nativeRead(args.array("queries"), cursor: args.string("expectedCursor"))
    case "observe": return try await observe(args)
    case "wait":
      guard let milliseconds = args.number("milliseconds"), milliseconds >= 0, milliseconds <= 1000 else {
        throw CollaborationError("invalid_wait", "Ожидание ограничено одной секундой.")
      }
      try await Task.sleep(for: .milliseconds(Int(milliseconds))); return .null
    case "page":
      let id = try await selectedID(args, page: true)
      return try await persistence { store in
        try store.readTransaction { _ in
          let page = try store.loadPage(id)
          return .object(["page": try page.graphicReadProjection(), "agentRevision": .string(page.agentStamp.revision),
            "drawingRevision": .string(page.drawingStamp.revision), "cursor": .string(String(try store.currentReadCursor()))])
        }
      }
    case "document":
      let id = try await selectedID(args, page: false)
      if let block = args.string("blockID") {
        return try await nativeRead([.object(["kind": .string("documentBlock"), "id": .string(id.uuidString), "elementID": .string(block)])])
      }
      return try await persistence { store in
        try store.readTransaction { _ in
          let document = try store.loadDocument(id), state = try store.loadDocumentState(id)
          return .object(["document": try .encode(document), "state": try .encode(state),
            "contentRevision": .string(document.contentStamp.revision), "stateRevision": .string(state.stamp.revision),
            "cursor": .string(String(try store.currentReadCursor()))])
        }
      }
    case "notebook":
      var query = args.fields; query["kind"] = .string("notebookDirectory")
      if query["limit"] == nil { query["limit"] = .number(4) }
      return try await nativeRead([.object(query)])
    case "board":
      var query = args.fields; query["kind"] = .string("sceneWindow")
      if query["id"] == nil || query["bounds"] == nil {
        let presence = try await nativeRead([.object(["kind": .string("presence")])]).array("values").first?.decode(SessionPresence.self)
        guard let presence else { throw CollaborationError("context_pending", "Текущее положение ещё не опубликовано.") }
        query["id"] = query["id"] ?? .string(presence.boardID.uuidString)
        let scale = max(presence.camera.scale, 0.0001)
        query["bounds"] = try query["bounds"] ?? .object(["anchor": .encode(presence.camera.center), "region": .object([
          "x": .number(-presence.viewport.x / scale / 2), "y": .number(-presence.viewport.y / scale / 2),
          "width": .number(presence.viewport.x / scale), "height": .number(presence.viewport.y / scale)])])
      }
      return try await nativeRead([.object(query)])
    case "context":
      var query = args.fields
      query["kind"] = .string(query["id"] == nil ? "contexts" : "contextEntries")
      return try await nativeRead([.object(query)])
    case "attention": return try await attention(args)
    case "code":
      var query = args.fields; query["kind"] = .string(query["file"] == nil ? "codeFragment" : "codeFragments")
      let result = try await nativeRead([.object(query)])
      if let id = args.string("id"), let value = result.array("values").first, value != .null {
        var fields = value.fields
        if let stamp = value["fragment"]?["stamp"], let revision = try? stamp.decode(VersionStamp.self).revision { fields["revision"] = .string(revision) }
        if let stamp = value["ink"]?["stamp"], let revision = try? stamp.decode(VersionStamp.self).revision { fields["inkRevision"] = .string(revision) }
        fields["link"] = .string("notebook://code/" + id.lowercased()); fields["cursor"] = result["cursor"]
        return .object(fields)
      }
      return result
    case "search", "reference", "referenceStatus":
      var request = args.fields; request["command"] = .string(method); return try await send(request)
    case "action":
      var request: [String: JSONValue] = ["command": .string("actionDetails")]
      for key in ["actionID", "contextID", "limit"] { request[key] = args[key] }
      var page: [String: JSONValue] = [:]
      for key in ["section", "offset", "after"] { page[key] = args[key] }
      page["limit"] = args["pageSize"]; request["actionPage"] = .object(page)
      return try await send(request)
    case "place": return try await send(["command": .string("placement"), "placement": args])
    case "render": return try await render(args)
    case "pageMap", "pageImage", "regions": return try await pageVision(method: method, arguments: args)
    case "presentation":
      var request: [String: JSONValue] = ["command": .string("presentation")]
      request["actionID"] = args["id"]; return try await send(request)
    case "exportStatus":
      guard let id = args.string("jobID").flatMap(UUID.init(uuidString:)) else { throw CollaborationError("invalid_export", "Нужен jobID.") }
      return try await persistence { try $0.scriptExportJob(id) ?? .object(["status": .string("missing")]) }
    default: throw CollaborationError("unknown_sdk_method", "Метод отсутствует в API v1.")
    }
  }

  private func selectedID(_ args: JSONValue, page: Bool) async throws -> UUID {
    if let supplied = args["id"] {
      guard case .string(let value) = supplied, let id = UUID(uuidString: value) else {
        throw CollaborationError("invalid_reference", "Переданный id должен быть точным UUID владельца.")
      }
      return id
    }
    let result = try await nativeRead([.object(["kind": .string("presence")])])
    guard let presence = try result.array("values").first?.decode(SessionPresence.self),
      let id = page ? presence.notebookPageID : presence.selectedItemID else {
      throw CollaborationError("target_required", "Укажите точный ID владельца.")
    }
    return id
  }

  private func observe(_ args: JSONValue) async throws -> JSONValue {
    try await persistence { store in
      try store.readTransaction { _ in
        let header = try store.workspaceHeader(), presence = try store.loadPresence()
        let shared = try store.sharedContexts(contextID: args.string("contextID").flatMap(UUID.init(uuidString:)), limit: 8)
        var keys: [String: JSONValue] = ["workspace": .string(header.stamp.revision),
          "board": .string(try store.targetContentRevision(target: .init(kind: .board, id: presence.boardID))),
          "spatialInk": header.spatialInkStamp.map { .string($0.revision) } ?? .null, "contexts": .string(shared.readCursor),
          "view": try .encode(presence)]
        var content: JSONValue = .object(["kind": .string(presence.mode.rawValue), "boardID": .string(presence.boardID.uuidString.lowercased())])
        if let pageID = presence.notebookPageID, presence.mode == .page {
          let page = try store.loadPage(pageID)
          keys["page:\(pageID):content"] = .string(page.agentStamp.revision)
          keys["page:\(pageID):ink"] = .string(page.drawingStamp.revision)
          content = .object(["kind": .string("page"), "id": .string(pageID.uuidString.lowercased()),
            "agentRevision": .string(page.agentStamp.revision), "drawingRevision": .string(page.drawingStamp.revision),
            "elements": .array(page.elements.prefix(32).map { .object(["id": .string($0.id), "kind": .string($0.kind.rawValue),
              "preview": .string(String($0.source.prefix(160)))]) }), "truncated": .bool(page.elements.count > 32)])
        } else if let selectedID = presence.selectedItemID, presence.mode == .document {
          let document = try store.loadDocument(selectedID), state = try store.loadDocumentState(selectedID)
          keys["document:\(selectedID):content"] = .string(document.contentStamp.revision)
          keys["document:\(selectedID):state"] = .string(state.stamp.revision)
          content = .object(["kind": .string("document"), "id": .string(selectedID.uuidString.lowercased()),
            "contentRevision": .string(document.contentStamp.revision), "stateRevision": .string(state.stamp.revision),
            "blocks": .array(document.blocks.prefix(32).map { .object(["id": .string($0.id), "kind": .string($0.kind.rawValue),
              "preview": .string(String($0.source.prefix(160)))]) }), "truncated": .bool(document.blocks.count > 32)])
        }
        let previous = args["since"]?.fields ?? [:]
        let changes: JSONValue = .object(["changed": .array(keys.keys.sorted().filter { previous[$0] != keys[$0] }.map(JSONValue.string)),
          "removed": .array(previous.keys.sorted().filter { keys[$0] == nil }.map(JSONValue.string))])
        let receipt = try store.loadCurrentViewReceipt()
        var image: JSONValue = .object(["status": .string("pending")])
        if let receipt, receipt.workspaceStamp == header.stamp, receipt.presence == presence,
          receipt.boardRevision == header.boardRevision, receipt.spatialInkStamp == header.spatialInkStamp {
          var fresh = true
          switch receipt.surface {
          case .page(_, let revision, _): fresh = try CurrentViewPageRevision(page: store.loadPage(revision.pageID)) == revision
          case .document(let revision, _, _):
            fresh = try CurrentViewDocumentRevision(document: store.loadDocument(revision.documentID), state: store.loadDocumentState(revision.documentID)) == revision
          default: break
          }
          if fresh { image = .object(["status": .string("ready"), "receipt": try .encode(receipt),
            "artifact": try .encode(NotebookArtifactRequest(kind: .currentView, expectedSHA256: receipt.pngSHA256))]) }
        }
        return .object(["status": .string("ready"), "header": try .encode(header), "presence": try .encode(presence),
          "contexts": try .encode(shared), "connection": try .encode(store.loadRuntimeStatus()), "content": content,
          "cursor": .string(String(try store.currentReadCursor())), "changeKeys": .object(keys), "changes": changes, "visual": image])
      }
    }
  }

  private func attention(_ args: JSONValue) async throws -> JSONValue {
    guard let contextID = args.string("contextID").flatMap(UUID.init(uuidString:)),
      let referenceID = args.string("referenceID").flatMap(UUID.init(uuidString:)) else {
      throw CollaborationError("invalid_reference", "Нужны contextID и referenceID из вопроса.")
    }
    return try await persistence { store in
      guard let source = try store.attentionEvidence(contextID: contextID, referenceID: referenceID) else {
        return .object(["status": .string("pending"), "code": .string("attention_not_delivered")])
      }
      let raw = try JSONValue.encode(source)
      var result: [String: JSONValue] = ["status": .string("source_pixels_unavailable"), "reference": raw["reference"] ?? .null,
        "payload": raw["payload"] ?? .null]
      if let image = raw["image"], let hash = image.string("sha256") {
        result["status"] = .string("source_pixels")
        result["artifact"] = .object(["kind": .string("attention"), "contextID": .string(contextID.uuidString),
          "referenceID": .string(referenceID.uuidString), "expectedSHA256": .string(hash)])
        result["pixelWidth"] = image["pixelWidth"]; result["pixelHeight"] = image["pixelHeight"]
      }
      return .object(result)
    }
  }

  private func render(_ args: JSONValue) async throws -> JSONValue {
    var request = args.fields; request["command"] = .string("render")
    let waiting = try await send(request)
    guard let id = waiting.string("id") else { return waiting }
    let result = try await nativeRead([.object(["kind": .string("targetRenderReceipt"), "id": .string(id)])])
    guard let receipt = result.array("values").first, receipt != .null else {
      return .object(["status": .string("pending"), "request": waiting])
    }
    var fields = receipt.fields
    if receipt.string("status") == "ready", let hash = receipt.string("pngSHA256") {
      let current = try await send(["command": .string("reference"), "target": args["target"] ?? .null])
      guard current["revision"] == waiting["sourceRevision"] else { throw CollaborationError("revision_conflict", "Владелец изменился при подготовке снимка.") }
      fields["artifact"] = .object(["kind": .string("target"), "id": .string(id), "expectedSHA256": .string(hash)])
    }
    return .object(fields)
  }

  private func pageVision(method: String, arguments args: JSONValue) async throws -> JSONValue {
    let id = try await selectedID(args, page: true)
    let page = try await persistence { try .encode($0.loadPage(id)) }.decode(PageDocument.self)
    if let expected = args.string("drawingRevision"), expected != page.drawingStamp.revision {
      throw CollaborationError("revision_conflict", "Чернила изменились; прочитайте новую карту.")
    }
    let snapshot = try await nativeRead([.object(["kind": .string("pageVisionReceipt"), "id": .string(id.uuidString)])])
    guard let receipt = snapshot.array("values").first, let stamp = receipt["drawingStamp"],
      try stamp.decode(VersionStamp.self) == page.drawingStamp,
      try receipt["pageSize"]?.decode(PageSize.self) == page.size else {
      return try await requestPageVision(id: id, revision: page.drawingStamp.revision)
    }
    if method == "pageMap" {
      var result: [String: JSONValue] = ["status": .string("ready"), "drawingRevision": .string(page.drawingStamp.revision), "map": receipt]
      if let since = args.string("sinceDrawingRevision") {
        let old = try await nativeRead([.object(["kind": .string("pageVisionReceipt"), "id": .string(id.uuidString), "revision": .string(since)])]).array("values").first
        let current = receipt.array("regions"), previous = old?.array("regions") ?? []
        let unchanged = current.filter { region in previous.contains { $0["id"] == region["id"] && $0["inkPNG_SHA256"] == region["inkPNG_SHA256"] } }
        result["delta"] = .object(["fromDrawingRevision": .string(since), "available": .bool(old != nil && old != .null),
          "unchangedRegionIDs": .array(unchanged.compactMap { $0["id"] }),
          "changedRegionIDs": .array(current.filter { region in !unchanged.contains { $0["id"] == region["id"] } }.compactMap { $0["id"] }),
          "removedRegionIDs": .array(previous.filter { region in !current.contains { $0["id"] == region["id"] } }.compactMap { $0["id"] })])
      }
      return .object(result)
    }
    let ink = args.string("mode") == "ink", mode = ink ? "ink" : "faithful"
    var artifacts: [JSONValue] = []
    if method == "pageImage", let hash = receipt.string(ink ? "inkPNG_SHA256" : "previewPNG_SHA256") {
      artifacts = [.object(["kind": .string("pageOverview"), "id": .string(id.uuidString), "mode": .string(mode), "expectedSHA256": .string(hash)])]
    } else {
      let ids = args.array("regionIDs")
      let strings: [String] = ids.compactMap { if case .string(let value) = $0 { value } else { nil } }
      guard (1...4).contains(ids.count), Set(strings).count == ids.count else {
        throw CollaborationError("invalid_regions", "Нужны от одной до четырёх разных областей текущей карты.")
      }
      for regionID in ids {
        guard let region = receipt.array("regions").first(where: { $0["id"] == regionID }),
          let hash = region.string(ink ? "inkPNG_SHA256" : "faithfulPNG_SHA256") else { throw CollaborationError("region_missing", "Область отсутствует в текущей карте.") }
        artifacts.append(.object(["kind": .string("pageRegion"), "id": .string(id.uuidString), "regionID": regionID,
          "mode": .string(mode), "expectedSHA256": .string(hash)]))
      }
    }
    for artifact in artifacts {
      do { _ = try await send(["command": .string("artifact"), "artifact": artifact]) }
      catch let error as CollaborationError where error.code == "artifact_missing" {
        return try await requestPageVision(id: id, revision: page.drawingStamp.revision)
      }
    }
    return .object(["status": .string("ready"), "drawingRevision": .string(page.drawingStamp.revision), "artifacts": .array(artifacts)])
  }

  private func requestPageVision(id: UUID, revision: String) async throws -> JSONValue {
    let request = try await send(["command": .string("pageVision"), "target": .object(["kind": .string("page"), "id": .string(id.uuidString)]),
      "expectedRevision": .string(revision)])
    if let requestID = request["id"] {
      let proof = try await nativeRead([.object(["kind": .string("targetRenderReceipt"), "id": requestID])]).array("values").first
      if proof?.string("status") == "error" {
        return .object(["status": .string("error"), "code": .string("render_failed"), "request": request,
          "diagnostics": proof?["diagnostics"] ?? .array([])])
      }
    }
    return .object(["status": .string("pending"), "request": request])
  }

  func validateImage(_ image: JSONValue) throws {
    guard let hash = image.string("expectedSHA256"), hash.count == 64,
      hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw CollaborationError("invalid_artifact", "Изображение требует точный SHA-256.") }
    if image.string("kind") == "attention" {
      guard image.string("contextID").flatMap(UUID.init(uuidString:)) != nil,
        image.string("referenceID").flatMap(UUID.init(uuidString:)) != nil else { throw CollaborationError("invalid_artifact", "Нужна сохранённая идентичность внимания.") }
    } else { _ = try image.decode(NotebookArtifactRequest.self) }
  }
}
