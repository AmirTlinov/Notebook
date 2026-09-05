import CryptoKit
import Foundation

public struct TargetRenderRequest: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let target: CollaborationTarget
  public let sourceRevision: String
  public let region: PageRect?
  public let worldOrigin: WorldPoint?
  public let pageIndex: Int
  public let createdAt: Date
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

  /// A held contact retains one causal cut, not an ever-growing message queue.
  public func merging(_ incoming: Self) throws -> Self {
    for envelope in [self, incoming] {
      guard Set(envelope.actions.map(\.id)).count == envelope.actions.count,
        Set(envelope.contexts.map(\.id)).count == envelope.contexts.count,
        Set(envelope.delivery.map(\.id)).count == envelope.delivery.count else {
        throw CollaborationError("invalid_content", "Сетевой срез содержит уникальные ID владельцев и ходов.")
      }
    }
    var content = content
    if let next = incoming.content {
      if content != nil { content!.merge(next) } else { content = next }
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
    let files = try collaborationSnapshot()
    return try Self.referenceRevision(target: target, elementID: elementID, files: files)
  }

  public static func referenceRevision(target: CollaborationTarget, elementID: String? = nil,
    files: [String: JSONValue]) throws -> String {
    let suffix = target.id.uuidString.lowercased() + ".json"
    let content: JSONValue
    switch target.kind {
    case .page:
      guard let page = files["pages/" + suffix] else { throw CollaborationError("target_missing", "Лист отсутствует.", target: target) }
      if let elementID {
        guard let element = page["elements"]?.array.first(where: { $0["id"]?.string == elementID }) else { throw CollaborationError("target_missing", "Элемент листа отсутствует.", target: target) }
        content = element.setting("frame", nil)
      } else { content = page.setting("collaboration", nil) }
    case .document:
      guard let document = files["documents/" + suffix] else { throw CollaborationError("target_missing", "Документ отсутствует.", target: target) }
      if let elementID {
        guard let block = document["blocks"]?.array.first(where: { $0["id"]?.string == elementID }) else { throw CollaborationError("target_missing", "Блок документа отсутствует.", target: target) }
        let state = files["document-states/" + suffix]?["records"]?.array.first { $0["id"]?.string == elementID }
        content = .object(["block": block, "state": state ?? .null])
      } else { content = .object(["document": document.setting("collaboration", nil), "state": files["document-states/" + suffix] ?? .null]) }
    case .board, .cover:
      guard let hierarchy = files["board.json"], let workspace = files["workspace.json"] else { throw CollaborationError("target_missing", "Доска отсутствует.", target: target) }
      let boardID = target.kind == .board ? target.id : target.boardID
      guard let boardID, let node = hierarchy["boards"]?.array.first(where: { $0.memberIdentity == boardID.uuidString.lowercased() }) else { throw CollaborationError("target_missing", "Доска отсутствует.", target: target) }
      let elements = node["board"]?["elements"]?.array.filter {
        $0["surface"]?["ownerID"]?.string.flatMap(UUID.init(uuidString:)) == target.id
          && $0["surface"]?["kind"]?.string == target.kind.rawValue
      } ?? []
      if let elementID {
        guard let element = elements.first(where: { $0["id"]?.string == elementID }) else { throw CollaborationError("target_missing", "Пространственный элемент отсутствует.", target: target) }
        content = element.setting("frame", nil).setting("worldOrigin", nil).setting("stamp", nil)
      } else if target.kind == .cover {
        let item = workspace["items"]?.array.first { $0.memberIdentity == target.id.uuidString.lowercased() }
        guard item != nil, let boardValue = node["board"],
          try boardValue.decode(BoardDocument.self).itemIDs.contains(target.id) else {
          throw CollaborationError("target_missing", "Предмет принадлежит другой доске либо отсутствует.", target: target)
        }
        let actions = files["spatial-ink.json"]?["actions"]?.array.filter { action in
          action["spans"]?.array.contains { $0["surface"]?["ownerID"]?.string.flatMap(UUID.init(uuidString:)) == target.id } == true
        } ?? []
        content = .object(["item": item ?? .null, "elements": .array(elements), "ink": .array(actions),
          "paperSize": files["documents/" + suffix]?["paperSize"] ?? .null])
      } else {
        let tree = try hierarchy.decode(BoardHierarchy.self)
        var descendants: Set<UUID> = [target.id]
        var pending = [target.id]
        while let id = pending.popLast(), let board = tree.board(id) {
          for child in board.itemIDs where tree.board(child) != nil && descendants.insert(child).inserted { pending.append(child) }
        }
        let itemIDs = Set(descendants.flatMap { tree.board($0)?.itemIDs ?? [] })
        let nodes = (hierarchy["boards"]?.array ?? []).filter { $0["id"]?.string.flatMap(UUID.init(uuidString:)).map(descendants.contains) == true }
        let items = (workspace["items"]?.array ?? []).filter { $0["id"]?.string.flatMap(UUID.init(uuidString:)).map(itemIDs.contains) == true }
        let ink = (files["spatial-ink.json"]?["actions"]?.array ?? []).filter { action in
          action["spans"]?.array.contains { span in
            guard let id = span["surface"]?["ownerID"]?.string.flatMap(UUID.init(uuidString:)) else { return false }
            return span["surface"]?["kind"]?.string == "board" ? descendants.contains(id) : itemIDs.contains(id)
          } == true
        }
        let paper: [JSONValue] = itemIDs.compactMap { id -> JSONValue? in files["documents/\(id.uuidString.lowercased()).json"]?["paperSize"].map { .object(["id":.string(id.uuidString.lowercased()),"size":$0]) } }.sorted { ($0["id"]?.string ?? "") < ($1["id"]?.string ?? "") }
        content = .object(["items":.array(items),"boards":.array(nodes),"ink":.array(ink),"paper":.array(paper)])
      }
    case .workspace: content = files["workspace.json"] ?? .null
    }
    return try collaborationHash(content)
  }

  public func requestTargetRender(target: CollaborationTarget, expectedRevision: String,
    region: PageRect? = nil, worldOrigin: WorldPoint? = nil, pageIndex: Int = 0) throws -> TargetRenderRequest {
    let files = try collaborationSnapshot()
    guard target.kind != .workspace else { throw CollaborationError("invalid_reference", "Снимок принадлежит доске, обложке, листу или странице документа.") }
    if let region {
      guard [region.x,region.y,region.width,region.height].allSatisfy(\.isFinite),
        region.width > 0, region.height > 0, region.width <= 4096, region.height <= 4096 else {
        throw CollaborationError("invalid_reference", "Область снимка имеет положительный размер до 4096 points.")
      }
    }
    guard (0...100_000).contains(pageIndex) else { throw CollaborationError("invalid_reference", "Номер страницы находится в допустимом диапазоне.") }
    let source = try Self.referenceRevision(target: target, files: files)
    let actual = try Self.targetContentRevision(target: target, files: files)
    guard actual == expectedRevision.lowercased() else {
      throw CollaborationError("revision_conflict", "Перед снимком содержимое изменилось.", target: target, expected: expectedRevision, actual: actual)
    }
    let key: JSONValue = .object(["target": try .encode(target), "source": .string(source),
      "region": try region.map(JSONValue.encode) ?? .null, "origin": try worldOrigin.map(JSONValue.encode) ?? .null, "page": .number(Double(pageIndex))])
    let hash = try collaborationHash(key)
    let hex = Array(hash)
    let uuid = String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-4" + String(hex[13..<16]) + "-8" + String(hex[17..<20]) + "-" + String(hex[20..<32])
    let request = TargetRenderRequest(id: UUID(uuidString: uuid)!, target: target, sourceRevision: source,
      region: region, worldOrigin: worldOrigin, pageIndex: pageIndex, createdAt: Date())
    try prepare()
    return try withMutationLock {
      let url = renderRequestsURL.appendingPathComponent(request.id.uuidString.lowercased() + ".json")
      let requests = try targetRenderRequests()
      let pending = requests.filter { !FileManager.default.fileExists(atPath:targetReceiptURL($0.id).path) }
      guard pending.count < 16 || requests.contains(where: { $0.id == request.id }) else {
        throw CollaborationError("snapshot_pending", "Очередь снимков занята активными запросами. Повторите после подготовки текущих областей.")
      }
      for obsolete in requests.filter({ FileManager.default.fileExists(atPath:targetReceiptURL($0.id).path) }).dropLast(64) {
        try? FileManager.default.removeItem(at:renderRequestsURL.appendingPathComponent(obsolete.id.uuidString.lowercased()+".json"))
        try? FileManager.default.removeItem(at:targetPNGURL(obsolete.id))
        try? FileManager.default.removeItem(at:targetReceiptURL(obsolete.id))
      }
      if FileManager.default.fileExists(atPath: url.path) {
        return try JSONDecoder().decode(TargetRenderRequest.self, from: Data(contentsOf: url))
      }
      try JSONEncoder().encode(request).write(to: url, options: .atomic)
      return request
    }
  }

  public static func targetContentRevision(target: CollaborationTarget, files: [String: JSONValue]) throws -> String {
    let stamp: JSONValue?
    switch target.kind {
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

  public func targetRenderRequests() throws -> [TargetRenderRequest] {
    try prepare()
    return try FileManager.default.contentsOfDirectory(at: renderRequestsURL, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(TargetRenderRequest.self, from: Data(contentsOf: $0)) }
      .sorted { $0.createdAt < $1.createdAt }
  }

  public func saveTargetRender(_ receipt: TargetRenderReceipt, png: Data? = nil) throws {
    try prepare()
    if let png { try png.write(to: targetPNGURL(receipt.request.id), options: .atomic) }
    try JSONEncoder().encode(receipt).write(to: targetReceiptURL(receipt.request.id), options: .atomic)
  }

  public func deviceActionReceipts() throws -> [DeviceActionReceipt] {
    try prepare()
    return try FileManager.default.contentsOfDirectory(at: deviceReceiptsURL, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(DeviceActionReceipt.self, from: Data(contentsOf: $0)) }
      .sorted { $0.id.uuidString < $1.id.uuidString }
  }

  public func saveDeviceActionReceipt(_ receipt: DeviceActionReceipt) throws {
    try prepare()
    try withMutationLock {
      let url = deviceReceiptsURL.appendingPathComponent(receipt.id.uuidString.lowercased() + ".json")
      var result = receipt
      if let data = try? Data(contentsOf:url), let previous = try? JSONDecoder().decode(DeviceActionReceipt.self,from:data) {
        result = previous.merging(receipt)
        guard result != previous else { return }
      }
      try JSONEncoder().encode(result).write(to:url,options:.atomic)
    }
  }

  public func receiveCollaboration(_ envelope: CollaborationEnvelope, local: CollaborationContent? = nil) throws -> CollaborationContent? {
    try prepare()
    let resolved = envelope.content != nil || !envelope.actions.isEmpty || !envelope.contexts.isEmpty || envelope.selection != nil
      ? try mergeCollaborationContent(envelope.content,local:local,actions:envelope.actions, contexts:envelope.contexts, selection:envelope.selection) : nil
    for receipt in envelope.delivery { try saveDeviceActionReceipt(receipt) }
    return resolved
  }
}

public func collaborationHash<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
}
