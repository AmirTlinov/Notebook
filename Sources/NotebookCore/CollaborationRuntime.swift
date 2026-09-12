import CryptoKit
import Foundation

public struct TargetRenderRequest: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let target: CollaborationTarget
  public let sourceRevision: String
  public let region: PageRect?
  public let worldOrigin: WorldPoint?
  public let pageIndex: Int
  /// A page-vision request asks only for final ink, its map and detail windows.
  /// Without this constraint the request is a composite content snapshot.
  public let pageVisionRevision: String?
  public let createdAt: Date

  /// A durable picture depends on both its content and the rendering recipe.
  /// Source revisions do not change with MathJax or spatial raster preparation;
  /// earlier successful or failed recipes therefore keep another address.
  static func compositeFingerprint(target: CollaborationTarget, source: String,
    region: PageRect?, worldOrigin: WorldPoint?, pageIndex: Int) throws -> String {
    var key: JSONValue = .object(["target": try .encode(target), "source": .string(source),
      "region": try region.map(JSONValue.encode) ?? .null,
      "origin": try worldOrigin.map(JSONValue.encode) ?? .null, "page": .number(Double(pageIndex))])
    if target.kind == .document { key = key.setting("renderer", .string("NotebookDocumentFragments/2")) }
    if target.kind == .board || target.kind == .cover {
      key = key.setting("renderer", .string("NotebookSpatialComposition/2"))
    }
    return try collaborationHash(key)
  }

  static func compositeID(target: CollaborationTarget, source: String,
    region: PageRect?, worldOrigin: WorldPoint?, pageIndex: Int) throws -> UUID {
    let hex = Array(try compositeFingerprint(target: target, source: source,
      region: region, worldOrigin: worldOrigin, pageIndex: pageIndex))
    let uuid = String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-4" + String(hex[13..<16])
      + "-8" + String(hex[17..<20]) + "-" + String(hex[20..<32])
    return UUID(uuidString: uuid)!
  }

  /// An executor cannot publish today's pixels under a different recipe's ID.
  /// Page vision has its own ink-only recipe and is validated by that executor.
  public func requireCurrentRenderingRecipe() throws {
    if pageVisionRevision != nil { return }
    let current = try Self.compositeID(target: target, source: sourceRevision,
      region: region, worldOrigin: worldOrigin, pageIndex: pageIndex)
    guard id == current else {
      throw CollaborationError("render_recipe_unavailable", "Запрос относится к другому способу отрисовки; запросите снимок текущего владельца снова.", target: target)
    }
  }
}

public struct RenderDiagnostic: Codable, Equatable, Sendable {
  public let kind: String
  public let elementID: String?
  public let message: String

  public init(kind: String, elementID: String? = nil, message: String) {
    self.kind = kind; self.elementID = elementID; self.message = message
  }
}

public struct TargetRenderReceipt: Codable, Equatable, Sendable {
  public let request: TargetRenderRequest
  public let status: String
  public let referenceFingerprint: String?
  public let pngSHA256: String?
  public let pixelSize: SpatialPoint?
  public let camera: SpatialCamera?
  public let diagnostics: [RenderDiagnostic]
  public let inkRegions: [PageRect]
  public let completedAt: Date

  public init(request: TargetRenderRequest, status: String, pngSHA256: String? = nil, referenceFingerprint: String? = nil,
    pixelSize: SpatialPoint? = nil, camera: SpatialCamera? = nil,
    diagnostics: [RenderDiagnostic] = [], inkRegions: [PageRect] = []) {
    self.request = request; self.status = status; self.pngSHA256 = pngSHA256; self.referenceFingerprint = referenceFingerprint
    self.pixelSize = pixelSize; self.camera = camera; self.diagnostics = diagnostics
    self.inkRegions = inkRegions
    completedAt = Date()
  }
}

public struct DeviceActionReceipt: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let deviceID: UUID
  public let receivedAt: Date
  public let revisions: [CollaborationExpectation]
  public var shown: [CollaborationExpectation]
  public var displayComplete: Bool
  public var visibleRegions: [CollaborationReference]

  public init(id: UUID, deviceID: UUID, receivedAt: Date = Date(), revisions: [CollaborationExpectation] = [], shown: [CollaborationExpectation] = [], displayComplete: Bool = false, visibleRegions: [CollaborationReference] = []) {
    self.id = id; self.deviceID = deviceID; self.receivedAt = receivedAt; self.revisions = revisions; self.shown = shown; self.displayComplete = displayComplete; self.visibleRegions = visibleRegions
  }
}

public struct CollaborationEnvelope: Codable, Equatable, Sendable {
  public let content: CollaborationContent?
  public let actions: [CollaborationReceipt]
  public let contexts: [SharedContext]
  public let selection: SharedContextSelection?
  public let delivery: [DeviceActionReceipt]

  public init(content: CollaborationContent? = nil, actions: [CollaborationReceipt] = [], contexts: [SharedContext] = [], selection: SharedContextSelection? = nil, delivery: [DeviceActionReceipt] = []) {
    self.content = content; self.actions = actions; self.contexts = contexts; self.selection = selection; self.delivery = delivery
  }

  private enum CodingKeys: String, CodingKey { case content, actions, contexts, selection, delivery }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    content = try values.decodeIfPresent(CollaborationContent.self, forKey: .content)
    actions = try values.decode([CollaborationReceipt].self, forKey: .actions)
    contexts = try values.decode([SharedContext].self, forKey: .contexts)
    selection = try values.decodeIfPresent(SharedContextSelection.self, forKey: .selection)
    delivery = try values.decode([DeviceActionReceipt].self, forKey: .delivery)
    try validate()
  }

  public func validate() throws {
    try content?.validate()
    guard Set(actions.map(\.id)).count == actions.count,
      Set(contexts.map(\.id)).count == contexts.count,
      Set(delivery.map(\.id)).count == delivery.count,
      actions.allSatisfy({ $0.id == $0.action.id }) else {
      throw CollaborationError("invalid_content", "Сетевой срез содержит уникальные ID владельцев и ходов.")
    }
    for context in contexts { try context.validate() }
  }

  /// A held contact retains one causal cut, not an ever-growing message queue.
  public func merging(_ incoming: Self) throws -> Self {
    try validate()
    try incoming.validate()
    var content = content
    if let next = incoming.content {
      if content != nil { try content!.merge(next) } else { content = next }
    }
    var actions = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
    for next in incoming.actions {
      if let old = actions[next.id] {
        guard old.action == next.action else { throw CollaborationError("action_id_conflict", "Разные ходы имеют одинаковый ID.") }
        if old.undo != nil { continue }
      }
      actions[next.id] = next
    }
    var contexts = Dictionary(uniqueKeysWithValues: contexts.map { ($0.id, $0) })
    for next in incoming.contexts {
      var merged = contexts[next.id] ?? .init(id: next.id)
      try merged.merge(next)
      contexts[next.id] = merged
    }
    var selection = selection
    if let next = incoming.selection, selection.map({ $0.stamp < next.stamp }) ?? true { selection = next }
    var delivery = Dictionary(uniqueKeysWithValues: delivery.map { ($0.id, $0) })
    for next in incoming.delivery { delivery[next.id] = delivery[next.id].map { $0.merging(next) } ?? next }
    return .init(content: content, actions: actions.values.sorted { $0.id.uuidString < $1.id.uuidString },
      contexts: contexts.values.sorted { $0.id.uuidString < $1.id.uuidString }, selection: selection,
      delivery: delivery.values.sorted { $0.id.uuidString < $1.id.uuidString })
  }
}

extension DeviceActionReceipt {
  func merging(_ next: Self) -> Self {
    guard revisions == next.revisions else { return receivedAt > next.receivedAt ? self : next }
    var result = next
    for item in shown where !result.shown.contains(item) { result.shown.append(item) }
    for region in visibleRegions where !result.visibleRegions.contains(where: { $0.id == region.id }) { result.visibleRegions.append(region) }
    result.displayComplete = displayComplete || next.displayComplete
    return result
  }
}

extension NotebookStore {
  public var renderRequestsURL: URL { collaborationURL.appendingPathComponent("render-requests", isDirectory: true) }
  public var targetPreviewsURL: URL { root.appendingPathComponent("previews/targets", isDirectory: true) }
  public var deviceReceiptsURL: URL { collaborationURL.appendingPathComponent("delivery", isDirectory: true) }

  public func targetPNGURL(_ id: UUID) -> URL { targetPreviewsURL.appendingPathComponent(id.uuidString.lowercased() + ".png") }
  public func targetReceiptURL(_ id: UUID) -> URL { targetPreviewsURL.appendingPathComponent(id.uuidString.lowercased() + ".json") }

  public func referenceRevision(target: CollaborationTarget, elementID: String? = nil) throws -> String {
    if elementID == nil, [.board, .cover, .page].contains(target.kind) {
      return try referenceIdentities(targets: [target])[0].revision
    }
    let files = try referenceSourceFiles(target: target, elementID: elementID)
    return try Self.referenceRevision(target: target, elementID: elementID, files: files)
  }

  public static func referenceRevision(target: CollaborationTarget, elementID: String? = nil,
    files: [String: JSONValue]) throws -> String {
    let suffix = target.id.uuidString.lowercased() + ".json"
    let content: JSONValue
    switch target.kind {
    case .codeFragment:
      guard elementID == nil, let fragment = files[codeFragmentFile(target.id)] else { throw CollaborationError("target_missing", "Фрагмент кода отсутствует.", target: target) }
      let actions = try (files["spatial-ink.json"]?["actions"]?.array ?? []).filter { action in
        try action["spans"]?.array.contains { try $0["surface"]?.decode(SurfaceID.self) == .codeFragment(target.id) } == true
      }.sorted { ($0["id"]?.string ?? "") < ($1["id"]?.string ?? "") }
      content = .object(["code": fragment, "ink": .array(actions)])
    case .page:
      guard let page = files["pages/" + suffix] else { throw CollaborationError("target_missing", "Лист отсутствует.", target: target) }
      if let elementID {
        guard let element = page["elements"]?.array.first(where: { $0.memberIdentity == collaborationIdentity(elementID) }) else { throw CollaborationError("target_missing", "Элемент листа отсутствует.", target: target) }
        content = element.setting("frame", nil)
      } else {
        return try boundReferenceRevision(target: target, files: files)
          ?? completePageReferenceRevision(target: target, value: page)
      }
    case .document:
      guard let document = files["documents/" + suffix] else { throw CollaborationError("target_missing", "Документ отсутствует.", target: target) }
      if let elementID {
        guard let block = document["blocks"]?.array.first(where: { $0.memberIdentity == collaborationIdentity(elementID) }) else { throw CollaborationError("target_missing", "Блок документа отсутствует.", target: target) }
        let state = files["document-states/" + suffix]?["records"]?.array.first { $0.memberIdentity == collaborationIdentity(elementID) }
        content = .object(["block": block, "state": state ?? .null])
      } else { content = .object(["document": document.setting("collaboration", nil), "state": files["document-states/" + suffix] ?? .null]) }
    case .board, .cover:
      guard let hierarchy = files["board.json"], files["workspace.json"] != nil else { throw CollaborationError("target_missing", "Доска отсутствует.", target: target) }
      let boardID = target.kind == .board ? target.id : target.boardID
      guard let boardID, let node = hierarchy["boards"]?.array.first(where: { $0.memberIdentity == boardID.uuidString.lowercased() }) else { throw CollaborationError("target_missing", "Доска отсутствует.", target: target) }
      let elements = node["board"]?["elements"]?.array.filter {
        $0["surface"]?["ownerID"]?.string.flatMap(UUID.init(uuidString:)) == target.id
          && $0["surface"]?["kind"]?.string == target.kind.rawValue
      } ?? []
      if let elementID {
        guard let element = elements.first(where: { $0.memberIdentity == collaborationIdentity(elementID) }) else { throw CollaborationError("target_missing", "Пространственный элемент отсутствует.", target: target) }
        content = element.setting("frame", nil).setting("worldOrigin", nil).setting("stamp", nil)
      } else {
        return try boundReferenceRevision(target: target, files: files) ?? completeReferenceRevision(target: target, files: files)
      }
    case .workspace: content = files["workspace.json"] ?? .null
    }
    return try collaborationHash(content)
  }

  public func requestTargetRender(target: CollaborationTarget, expectedRevision: String,
    region: PageRect? = nil, worldOrigin: WorldPoint? = nil, pageIndex: Int = 0) throws -> TargetRenderRequest {
    try prepare()
    return try withMutationLock {
      try enqueueTargetRender(target: target, expectedRevision: expectedRevision,
        region: region, worldOrigin: worldOrigin, pageIndex: pageIndex)
    }
  }

  private func enqueueTargetRender(target: CollaborationTarget, expectedRevision: String,
    region: PageRect?, worldOrigin: WorldPoint?, pageIndex: Int) throws -> TargetRenderRequest {
    guard target.kind != .workspace && target.kind != .codeFragment else { throw CollaborationError("invalid_reference", "Снимок принадлежит доске, обложке, листу или странице документа.") }
    if let region {
      guard [region.x,region.y,region.width,region.height].allSatisfy(\.isFinite),
        region.width > 0, region.height > 0, region.width <= 4096, region.height <= 4096 else {
        throw CollaborationError("invalid_reference", "Область снимка имеет положительный размер до 4096 points.")
      }
    }
    guard (0...100_000).contains(pageIndex) else { throw CollaborationError("invalid_reference", "Номер страницы находится в допустимом диапазоне.") }
    let source = try referenceRevision(target: target)
    let actual = try targetContentRevision(target: target)
    guard actual == expectedRevision.lowercased() else {
      throw CollaborationError("revision_conflict", "Перед снимком содержимое изменилось.", target: target, expected: expectedRevision, actual: actual)
    }
    let id = try TargetRenderRequest.compositeID(target: target, source: source,
      region: region, worldOrigin: worldOrigin, pageIndex: pageIndex)
    let request = TargetRenderRequest(id: id, target: target, sourceRevision: source,
      region: region, worldOrigin: worldOrigin, pageIndex: pageIndex, pageVisionRevision: nil, createdAt: Date())
    return try enqueueRenderRequest(request)
  }

  /// The page itself is the addressed source. A cold ink map does not load or
  /// enqueue the rest of the catalog and does not depend on agent elements.
  public func requestPageVision(pageID: UUID, expectedRevision: String) throws -> TargetRenderRequest {
    try prepare()
    return try withMutationLock {
      let target = CollaborationTarget(kind: .page, id: pageID)
      guard (try hasStoredValue(pageFile(pageID))) else {
        throw CollaborationError("target_missing", "Лист отсутствует.", target: target)
      }
      let page = try loadPage(pageID)
      guard page.drawingStamp.revision == expectedRevision.lowercased() else {
        throw CollaborationError("revision_conflict", "Перед подготовкой карты чернила изменились.",
          target: target, expected: expectedRevision, actual: page.drawingStamp.revision)
      }
      let source = try Self.pageVisionSourceRevision(page)
      let hash = Array(try collaborationHash(JSONValue.object(["pageVision": .string(source)])))
      let uuid = String(hash[0..<8]) + "-" + String(hash[8..<12]) + "-4" + String(hash[13..<16])
        + "-8" + String(hash[17..<20]) + "-" + String(hash[20..<32])
      let request = TargetRenderRequest(id: UUID(uuidString: uuid)!, target: target,
        sourceRevision: source, region: nil, worldOrigin: nil, pageIndex: 0,
        pageVisionRevision: page.drawingStamp.revision, createdAt: Date())
      for obsolete in try targetRenderRequests() where obsolete.target == target
        && obsolete.pageVisionRevision != nil && obsolete.id != request.id
        && !FileManager.default.fileExists(atPath: targetReceiptURL(obsolete.id).path) {
        try publishRecords(writes: [:], removals: ["collaboration/render-requests/" + obsolete.id.uuidString.lowercased() + ".json"])
      }
      // A deleted or corrupted derivative can be rebuilt with the same source
      // identity. An execution error remains explicit until the source changes.
      if let data = try? Data(contentsOf: targetReceiptURL(request.id)),
        let receipt = try? JSONDecoder().decode(TargetRenderReceipt.self, from: data),
        receipt.status == "ready", !hasCurrentPageVision(page) {
        try FileManager.default.removeItem(at: targetReceiptURL(request.id))
      }
      return try enqueueRenderRequest(request)
    }
  }

  public static func pageVisionSourceRevision(_ page: PageDocument) throws -> String {
    try collaborationHash(JSONValue.object(["id": .string(page.id.uuidString.lowercased()),
      "size": try .encode(page.size), "drawingStamp": try .encode(page.drawingStamp),
      "ink": .string(SHA256.hash(data: page.drawingData).map { String(format: "%02x", $0) }.joined())]))
  }

  private func enqueueRenderRequest(_ request: TargetRenderRequest) throws -> TargetRenderRequest {
    let url = renderRequestsURL.appendingPathComponent(request.id.uuidString.lowercased() + ".json")
    let requests = try targetRenderRequests()
    let pending = requests.filter { !FileManager.default.fileExists(atPath: targetReceiptURL($0.id).path) }
    guard pending.count < 16 || requests.contains(where: { $0.id == request.id }) else {
      throw CollaborationError("snapshot_pending", "Очередь снимков занята активными запросами. Повторите после подготовки текущих областей.")
    }
    for obsolete in requests.filter({ FileManager.default.fileExists(atPath: targetReceiptURL($0.id).path) }).dropLast(64) {
      try? publishRecords(writes: [:], removals: ["collaboration/render-requests/" + obsolete.id.uuidString.lowercased() + ".json"])
      try? FileManager.default.removeItem(at: targetPNGURL(obsolete.id))
      try? FileManager.default.removeItem(at: targetReceiptURL(obsolete.id))
    }
    if let previous = try storedValue(logicalAddress(url)) { return try previous.decode(TargetRenderRequest.self) }
    try publishRecords(writes: [logicalAddress(url): try .encode(request)])
    return request
  }

  public static func targetContentRevision(target: CollaborationTarget, files: [String: JSONValue]) throws -> String {
    let stamp: JSONValue?
    switch target.kind {
    case .codeFragment: stamp = files[codeFragmentFile(target.id)]?["stamp"]
    case .page: stamp = files["pages/\(target.id.uuidString.lowercased()).json"]?["agentStamp"]
    case .document: stamp = files["documents/\(target.id.uuidString.lowercased()).json"]?["contentStamp"]
    case .workspace: stamp = files["workspace.json"]?["stamp"]
    case .board, .cover:
      let id = target.boardID ?? target.id
      stamp = files["board.json"]?["boards"]?.array.first { $0.memberIdentity == id.uuidString.lowercased() }?["board"]?["stamp"]
    }
    guard let stamp else { throw CollaborationError("target_missing", "Владелец отсутствует.", target: target) }
    return try stamp.decode(VersionStamp.self).revision
  }

  public func targetRenderRequests(target: CollaborationTarget? = nil, afterID: UUID? = nil, limit: Int = 80) throws -> [TargetRenderRequest] {
    guard (1...128).contains(limit) else { throw NotebookStorageError.limitExceeded("render_request_page") }
    return try readTransaction { _ in
      var clause = "", arguments: [NotebookSQLValue] = []
      if let target { clause += " AND context_id=?"; arguments.append(.text(Self.renderTargetKey(target))) }
      if let afterID {
        let address = "collaboration/render-requests/" + afterID.uuidString.lowercased() + ".json#"
        guard let time = try currentSQL!.rows("SELECT created_at FROM metadata_index WHERE address=? AND kind='renderRequest'", [.text(address)]).first?[0] else { throw NotebookStorageError.transactionConflict }
        clause += " AND (created_at>? OR (created_at=? AND address>?))"; arguments += [time, time, .text(address)]
      }
      arguments.append(.integer(Int64(limit)))
      let rows = try currentSQL!.rows("SELECT address FROM metadata_index WHERE kind='renderRequest'" + clause + " ORDER BY created_at,address LIMIT ?", arguments)
      return try rows.map { row in
        guard let value = try storedValue(String(row[0].text!.dropLast())) else { throw NotebookStorageError.corruptRecord("render request") }
        return try value.decode(TargetRenderRequest.self)
      }
    }
  }

  static func renderTargetKey(_ target: CollaborationTarget) -> String {
    target.kind.rawValue + ":" + target.id.uuidString.lowercased() + ":" + (target.boardID?.uuidString.lowercased() ?? "")
  }

  public func saveTargetRender(_ receipt: TargetRenderReceipt, png: Data? = nil) throws {
    try prepare()
    if let png { try png.write(to: targetPNGURL(receipt.request.id), options: .atomic) }
    try JSONEncoder().encode(receipt).write(to: targetReceiptURL(receipt.request.id), options: .atomic)
    try commandTransaction {
      try currentSQL!.run("UPDATE metadata_index SET status=? WHERE address=? AND kind='renderRequest'", [.text(receipt.status), .text("collaboration/render-requests/" + receipt.request.id.uuidString.lowercased() + ".json#")])
    }
  }

  public func deviceActionReceipts() throws -> [DeviceActionReceipt] {
    try readTransaction { _ in
      try storedValues(prefix: "collaboration/delivery/").map { try $0.decode(DeviceActionReceipt.self) }
        .sorted { $0.id.uuidString < $1.id.uuidString }
    }
  }

  public func saveDeviceActionReceipt(_ receipt: DeviceActionReceipt) throws {
    try commandTransaction {
      let path = "collaboration/delivery/" + receipt.id.uuidString.lowercased() + ".json"
      let previous = try storedValue(path)?.decode(DeviceActionReceipt.self)
      let result = previous?.merging(receipt) ?? receipt
      if result != previous { try publishRecords(writes: [path: try .encode(result)]) }
    }
  }

  public func receiveCollaboration(_ envelope: CollaborationEnvelope, local: CollaborationContent? = nil) throws -> CollaborationContent? {
    try envelope.validate()
    try prepare()
    return try commandTransaction {
    let resolved = envelope.content != nil || !envelope.actions.isEmpty || !envelope.contexts.isEmpty || envelope.selection != nil
      ? try mergeCollaborationContent(envelope.content,local:local,actions:envelope.actions, contexts:envelope.contexts, selection:envelope.selection) : nil
    for receipt in envelope.delivery { try saveDeviceActionReceipt(receipt) }
    return resolved
    }
  }
}

public func collaborationHash<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
}
