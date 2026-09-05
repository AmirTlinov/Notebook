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
  public let pngSHA256: String?
  public let pixelSize: SpatialPoint?
  public let camera: SpatialCamera?
  public let diagnostics: [RenderDiagnostic]
  public let inkRegions: [PageRect]
  public let completedAt: Date

  public init(request: TargetRenderRequest, status: String, pngSHA256: String? = nil,
    pixelSize: SpatialPoint? = nil, camera: SpatialCamera? = nil,
    diagnostics: [RenderDiagnostic] = [], inkRegions: [PageRect] = []) {
    self.request = request; self.status = status; self.pngSHA256 = pngSHA256
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
  public var visibleRegions: [CollaborationReference]

  public init(id: UUID, deviceID: UUID, receivedAt: Date = Date(), revisions: [CollaborationExpectation] = [], shown: [CollaborationExpectation] = [], visibleRegions: [CollaborationReference] = []) {
    self.id = id; self.deviceID = deviceID; self.receivedAt = receivedAt; self.revisions = revisions; self.shown = shown; self.visibleRegions = visibleRegions
  }
}

public struct CollaborationEnvelope: Codable, Equatable, Sendable {
  public let content: CollaborationContent?
  public let actions: [CollaborationReceipt]
  public let attention: [SharedAttention]
  public let delivery: [DeviceActionReceipt]

  public init(content: CollaborationContent? = nil, actions: [CollaborationReceipt] = [], attention: [SharedAttention] = [], delivery: [DeviceActionReceipt] = []) {
    self.content = content; self.actions = actions; self.attention = attention; self.delivery = delivery
  }
}

extension NotebookStore {
  public var renderRequestsURL: URL { collaborationURL.appendingPathComponent("render-requests", isDirectory: true) }
  public var targetPreviewsURL: URL { root.appendingPathComponent("previews/targets", isDirectory: true) }
  public var deviceReceiptsURL: URL { collaborationURL.appendingPathComponent("delivery", isDirectory: true) }

  public func targetPNGURL(_ id: UUID) -> URL { targetPreviewsURL.appendingPathComponent(id.uuidString.lowercased() + ".png") }
  public func targetReceiptURL(_ id: UUID) -> URL { targetPreviewsURL.appendingPathComponent(id.uuidString.lowercased() + ".json") }

  public func sharedAttention() throws -> [SharedAttention] {
    try prepare()
    return try withMutationLock { try readAttention() }
  }

  private func readAttention() throws -> [SharedAttention] {
    try [SharedAttention.Author.human, .agent].compactMap { author in
      let url = collaborationURL.appendingPathComponent("attention-\(author.rawValue).json")
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      return try JSONDecoder().decode(SharedAttention.self, from: Data(contentsOf: url))
    }
  }

  public func saveSharedAttention(_ attention: SharedAttention) throws {
    try prepare()
    try withMutationLock {
      let previous = try readAttention().first { $0.author == attention.author }
      guard previous == nil || previous!.stamp < attention.stamp else { return }
      if let reference = attention.reference {
        guard reference.label.count <= 1000, reference.pageIndex.map({ (0...100_000).contains($0) }) ?? true else {
          throw CollaborationError("invalid_reference", "Указание имеет подпись и конечную страницу.")
        }
      }
      try JSONEncoder().encode(attention).write(to: collaborationURL.appendingPathComponent("attention-\(attention.author.rawValue).json"), options: .atomic)
    }
  }

  public func pointTo(_ reference: CollaborationReference?, actor: UUID) throws -> SharedAttention {
    let current = try sharedAttention().first { $0.author == .agent }?.stamp ?? .init(counter: 0, actor: actor)
    guard let next = current.advanced(by: actor) else { throw CollaborationError("version_exhausted", "Версия указания достигла предела.") }
    let value = SharedAttention(author: .agent, reference: reference, stamp: next)
    try saveSharedAttention(value)
    return value
  }

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
        guard item != nil else { throw CollaborationError("target_missing", "Предмет отсутствует.", target: target) }
        let actions = files["spatial-ink.json"]?["actions"]?.array.filter { action in
          action["spans"]?.array.contains { $0["surface"]?["ownerID"]?.string.flatMap(UUID.init(uuidString:)) == target.id } == true
        } ?? []
        content = .object(["item": item ?? .null, "elements": .array(elements), "ink": .array(actions),
          "paperSize": files["documents/" + suffix]?["paperSize"] ?? .null])
      } else {
        content = .object(["workspace": workspace, "hierarchy": hierarchy, "ink": files["spatial-ink.json"] ?? .null])
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
    try withMutationLock {
      let url = renderRequestsURL.appendingPathComponent(request.id.uuidString.lowercased() + ".json")
      if !FileManager.default.fileExists(atPath: url.path) { try JSONEncoder().encode(request).write(to: url, options: .atomic) }
    }
    return request
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
  }

  public func saveDeviceActionReceipt(_ receipt: DeviceActionReceipt) throws {
    try prepare()
    try withMutationLock {
      try JSONEncoder().encode(receipt).write(to: deviceReceiptsURL.appendingPathComponent(receipt.id.uuidString.lowercased() + ".json"), options: .atomic)
    }
  }

  public func receiveCollaboration(_ envelope: CollaborationEnvelope) throws {
    try prepare()
    for attention in envelope.attention { try saveSharedAttention(attention) }
    for receipt in envelope.delivery { try saveDeviceActionReceipt(receipt) }
    try withMutationLock {
      for incoming in envelope.actions {
        let url = collaborationActionsURL.appendingPathComponent(incoming.id.uuidString.lowercased() + ".json")
        if let data = try? Data(contentsOf: url), let current = try? JSONDecoder().decode(CollaborationReceipt.self, from: data) {
          guard current.action == incoming.action else { throw CollaborationError("action_id_conflict", "Разные ходы имеют одинаковый ID.") }
          if current.undo != nil || current == incoming { continue }
        }
        try JSONEncoder().encode(incoming).write(to: url, options: .atomic)
      }
    }
  }
}

public func collaborationHash<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
}
