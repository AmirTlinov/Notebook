import Foundation
import CryptoKit
import NotebookCore

enum NotebookScriptAPI {
  static let readMethods: Set<String> = ["help", "observe", "read", "readMany", "board", "notebook", "page", "document",
    "context", "attention", "code", "search", "reference", "referenceStatus", "action", "render", "pageMap",
    "pageImage", "regions", "place", "prepareTldraw", "exportStatus", "presentation", "wait"]
  static var help: JSONValue { .object([
    "status": .string("ready"), "api_version": .number(2), "language": .string("TypeScript 7.0.2 or ECMAScript / QuickJS 2026-06-04"),
    "limits": .object(["active_runs": .number(1), "queued_runs": .number(8), "source_bytes": .number(262144),
      "arguments_bytes": .number(1048576), "heap_bytes": .number(134217728), "stack_bytes": .number(1048576),
      "cpu_seconds": .number(5), "wall_seconds": .number(30), "tool_reply_seconds": .number(4), "outstanding_calls": .number(4),
      "host_calls": .number(1024), "effects": .number(128), "output_bytes": .number(4194304),
      "output_event_bytes": .number(262144), "result_bytes": .number(262144), "output_page_bytes": .number(1048576)]),
    "reads": .array(readMethods.sorted().map(JSONValue.string)),
    "effects": .array(["transaction(key, action)", "undo(key, {actionID})", "point(key, {references, contextID?, replyTo?})",
      "present(key, {view, steps})", "cancelPresentation(key, {id})", "export(key, {documentID, format?:pdf|png|svg|html|package|mp4, moment?:saved|presented, attention?, pageIndex?, pixelWidth?, blockID?, video?})", "cancelExport(key, {jobID})"].map(JSONValue.string)),
    "utilities": .array(["await nb.id(key)", "await emit(value)", "await emitImage(artifact)", "await nb.wait({milliseconds:100})"].map(JSONValue.string)),
    "read_contract": .string("Reads return Snapshot {data,basis,coverage,cursor}; readMany returns a tuple with per-query coverages from one WAL snapshot. IDs, revisions and continuation cursors come from owners, never inferred from omitted data."),
    "execution_contract": .string("Async TypeScript/JavaScript with args, nb, emit and emitImage. language defaults to javascript; typescript is explicitly selected, strictly checked and compiled by pinned CLI before QuickJS, never guessed or retried as JS. No Node, Python, DOM, require, fetch, filesystem, network, imports, user paths/configuration, SQLite or bytecode. Same run_id+language+code+args attaches without recompilation; changed payload conflicts. Resume never replays source or restores a heap. Mac owns the 30s active-run wall deadline including preparation and XPC launch; TS preparation has its own 10s ceiling. Read help('execution') for all compiler limits."),
    "reply_deadline": .string("One MCP reply has four seconds total, including owner admission and images. response_pending includes run_id, original after_seq and admission unknown/confirmed. It never cancels an accepted write. Resume that ID and cursor. If run_missing with after_seq:0, retry the identical start, never a fresh ID. wait_ms is an upper bound from native handler entry, not after admission; the adapter shortens it to leave room for IPC response."),
    "mutation_contract": .string("Every effect requires a stable key. One transaction is atomic and undoable; a whole program may save several effects. Cancellation prevents new effects and reports accepted native outcomes. Native undo preserves later human edits."),
    "images": .string("Image reads return opaque descriptors with exact hashes. emitImage freezes exact pixels in the native output journal; image bytes count toward 4 MiB per run. Up to four image events per resume page. JavaScript receives no file capability."),
    "exports": .string("export produces the canonical vector PDF or one PNG page at explicit pixelWidth (default 1600), without silent downsampling. It admits one immutable saved source/state cut from a WAL snapshot; keep jobID and read exportStatus after JS ends; cancelExport(key,{jobID}) durably cancels an unfinished job. Cancellation never changes a previously saved artifact; the final writer fence decides the race. At most two jobs render in the same pinned offline canonical print owner as paper, without touching a live program. Source/state changes before publication fail revision_conflict. The receipt binds cutSHA256/stateRevision and all artifacts. TeX <=4 MiB; composed PDF/assets stream through V2 4 MiB parts and 1 MiB read windows, without binary IPC. Descriptor <=1 MiB / 16384 parts. The existing canonical typesetter retains its own input/layout bounds."),
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
    return .object(["api_version": .number(2), "topic": .string(topic), "contract": value])
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

  func snapshotRead(_ queries: [JSONValue], cursor: String? = nil, many: Bool = false) async throws -> JSONValue {
    var request: [String: JSONValue] = ["command": .string("read"), "readSnapshots": .bool(true), "queries": .array(queries)]
    request["expectedCursor"] = cursor.map(JSONValue.string)
    let snapshots = try await send(request).decode([NotebookSnapshot].self)
    if !many {
      guard let snapshot = snapshots.first, snapshots.count == 1 else { throw CollaborationError("invalid_read", "Нужен один адрес чтения.") }
      return try .encode(snapshot)
    }
    guard let first = snapshots.first else { throw CollaborationError("invalid_read", "readMany требует хотя бы одно чтение.") }
    let basis = try NotebookReadBasis.merging(snapshots.map(\.basis))
    // Each member retains its own continuation; the tuple and its merged basis
    // belong to one native snapshot, not sequential fresh reads.
    var result = try JSONValue.encode(NotebookSnapshot(data: .array(snapshots.map(\.data)), basis: basis,
      coverage: .init(complete: snapshots.allSatisfy { $0.coverage.complete }), cursor: first.cursor)).fields
    result["coverages"] = try .encode(snapshots.map(\.coverage))
    return .object(result)
  }

  private func evidenceSnapshot(_ data: JSONValue) async throws -> JSONValue {
    try await persistence { store in
      try .encode(NotebookSnapshot(data: data, basis: store.readBasis(targets: []), cursor: String(store.currentReadCursor())))
    }
  }

  func read(method: String, arguments args: JSONValue) async throws -> JSONValue {
    guard case .object = args else { throw CollaborationError("invalid_arguments", "Метод SDK получает объект аргументов из nb.help(method).") }
    switch method {
    case "help": return try NotebookScriptAPI.documentation(args.string("topic"))
    case "read": return try await snapshotRead([args])
    case "readMany": return try await snapshotRead(args.array("queries"), cursor: args.string("expectedCursor"), many: true)
    case "observe": return try await observe(args)
    case "prepareTldraw":
      guard let source = args.string("source"), let namespace = args.string("namespace").flatMap(UUID.init(uuidString:)) else {
        throw CollaborationError("invalid_arguments", "Нужны source и namespace из nb.id(key).")
      }
      let selected = try args["selectedIDs"]?.decode([String].self)
      let scale = try args["scale"]?.decode(Double.self) ?? 1
      // Conversion does not reserve the save queue or grant destination authority.
      let task = Task.detached(priority: .userInitiated) {
        try NotebookTldrawImport.prepare(source:source,selectedIDs:selected,namespace:namespace,scale:scale)
      }
      let fragment = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
      return try await evidenceSnapshot(.encode(fragment))
    case "wait":
      guard let milliseconds = args.number("milliseconds"), milliseconds >= 0, milliseconds <= 1000 else {
        throw CollaborationError("invalid_wait", "Ожидание ограничено одной секундой.")
      }
      try await Task.sleep(for: .milliseconds(Int(milliseconds))); return .null
    case "page", "document":
      let page = method == "page", id = try await selectedID(args, page: page)
      let member = args.string(page ? "elementID" : "blockID")
      var query: [String: JSONValue] = ["kind": .string(page ? (member == nil ? "page" : "pageElement") : (member == nil ? "document" : "documentBlock")), "id": .string(id.uuidString)]
      query["elementID"] = member.map(JSONValue.string)
      return try await snapshotRead([.object(query)])
    case "notebook":
      var query = args.fields; query["kind"] = .string("notebookDirectory")
      if query["limit"] == nil { query["limit"] = .number(4) }
      return try await snapshotRead([.object(query)])
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
      return try await snapshotRead([.object(query)])
    case "context":
      var query = args.fields
      query["kind"] = .string(query["id"] == nil ? "contexts" : "contextEntries")
      return try await snapshotRead([.object(query)])
    case "attention": return try await evidenceSnapshot(attention(args))
    case "code":
      var query = args.fields; query["kind"] = .string(query["file"] == nil ? "codeFragment" : "codeFragments")
      return try await snapshotRead([.object(query)])
    case "search", "reference", "referenceStatus":
      var request = args.fields; request["command"] = .string(method); request["readSnapshots"] = .bool(true); return try await send(request)
    case "action":
      var request: [String: JSONValue] = ["command": .string("actionDetails"), "readSnapshots": .bool(true)]
      for key in ["actionID", "contextID", "limit", "next"] { request[key] = args[key] }
      var page: [String: JSONValue] = [:]
      for key in ["section", "offset", "after", "actionVersion"] { page[key] = args[key] }
      page["limit"] = args["pageSize"]; request["actionPage"] = .object(page)
      return try await send(request)
    case "place": return try await send(["command": .string("placement"), "placement": args, "readSnapshots": .bool(true)])
    case "render": return try await evidenceSnapshot(render(args))
    case "pageMap", "pageImage", "regions": return try await evidenceSnapshot(pageVision(method: method, arguments: args))
    case "presentation":
      var request: [String: JSONValue] = ["command": .string("presentation")]
      request["actionID"] = args["id"]; return try await evidenceSnapshot(send(request))
    case "exportStatus":
      guard let id = args.string("jobID").flatMap(UUID.init(uuidString:)) else { throw CollaborationError("invalid_export", "Нужен jobID.") }
      return try await persistence { store in
        try .encode(NotebookSnapshot(data: store.scriptExportJob(id) ?? .object(["status": .string("missing")]), basis: store.readBasis(targets: []), cursor: String(store.currentReadCursor())))
      }
    default: throw CollaborationError("unknown_sdk_method", "Метод отсутствует в API v2.")
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
    let page = try await persistence { try .encode($0.readContentHeader(target: .init(kind: .page, id: id))) }.decode(NotebookContentHeader.self)
    guard let drawing = page.inkStamp, let size = page.size else { throw CollaborationError("target_missing", "Нет метаданных листа.") }
    if let expected = args.string("drawingRevision"), expected != drawing.revision {
      throw CollaborationError("revision_conflict", "Чернила изменились; прочитайте новую карту.")
    }
    let snapshot = try await nativeRead([.object(["kind": .string("pageVisionReceipt"), "id": .string(id.uuidString)])])
    guard let receipt = snapshot.array("values").first, let stamp = receipt["drawingStamp"],
      try stamp.decode(VersionStamp.self) == drawing,
      try receipt["pageSize"]?.decode(PageSize.self) == size else {
      return try await requestPageVision(id: id, revision: drawing.revision)
    }
    if method == "pageMap" {
      var result: [String: JSONValue] = ["status": .string("ready"), "drawingRevision": .string(drawing.revision), "map": receipt]
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
        return try await requestPageVision(id: id, revision: drawing.revision)
      }
    }
    return .object(["status": .string("ready"), "drawingRevision": .string(drawing.revision), "artifacts": .array(artifacts)])
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
