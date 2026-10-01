import Foundation
import CryptoKit

/// A browser supplies one bounded projection; physical content stays native.
public struct NotebookPanelAppearanceProjection: Codable, Equatable, Sendable {
  public let viewport: SpatialPoint
  public let pixelScale: Double
  public let camera: SpatialCamera?
  public init(viewport: SpatialPoint, pixelScale: Double, camera: SpatialCamera? = nil) {
    self.viewport = viewport; self.pixelScale = pixelScale; self.camera = camera
  }
  public func validated() throws {
    guard viewport.x.isFinite, viewport.y.isFinite, (1...2048).contains(viewport.x),
      (1...2048).contains(viewport.y), pixelScale.isFinite, (0.5...2).contains(pixelScale),
      viewport.x * viewport.y * pixelScale * pixelScale <= 4_194_304,
      camera?.isValid != false else { throw CollaborationError("resource_limit", "Проекция панели ограничена 2048 points и четырьмя миллионами pixels.") }
  }
}

public struct NotebookPanelPresentationRequest: Codable, Sendable {
  public let workspaceID: UUID?
  public let target: CollaborationTarget?
  public let appearance: NotebookPanelAppearanceProjection
  public let knownCursor: String?
  public let knownRequestID: UUID?
  public init(workspaceID: UUID? = nil, target: CollaborationTarget? = nil,
    appearance: NotebookPanelAppearanceProjection, knownCursor: String? = nil, knownRequestID: UUID? = nil) {
    self.workspaceID = workspaceID; self.target = target; self.appearance = appearance; self.knownCursor = knownCursor
    self.knownRequestID = knownRequestID
  }
}

/// The existing addressed render queue owns this immutable, workspace-pinned recipe.
public struct NotebookPanelRenderProjection: Codable, Equatable, Sendable {
  public static let maximumSubjects = 16
  public static let maximumEncodedBytes = 16 * 1024 * 1024
  public static let maximumDecodedPixels = 32 * 1024 * 1024
  public let workspaceID: UUID
  public let camera: SpatialCamera
  public let viewport: SpatialPoint
  public let pixelScale: Double
  public init(workspaceID: UUID, camera: SpatialCamera, viewport: SpatialPoint, pixelScale: Double) {
    self.workspaceID = workspaceID; self.camera = camera; self.viewport = viewport; self.pixelScale = pixelScale
  }
  public func validated() throws {
    try NotebookPanelAppearanceProjection(viewport: viewport, pixelScale: pixelScale, camera: camera).validated()
  }
  public var worldOrigin: WorldPoint { camera.screenToWorld(.zero, viewport: viewport) }
  public var readBounds: NotebookReadBounds {
    .init(anchor: worldOrigin, region: .init(x: 0, y: 0, width: viewport.x / camera.scale, height: viewport.y / camera.scale))
  }
}

/// Eligibility grants manipulation only; every other source remains in the
/// native painter. In particular, measured contacts already belong to ink.
public enum NotebookPanelEditableSubject {
  public static func allows(_ entry: JSONValue) -> Bool {
    guard let source = entry["source"], source["parentID"] == nil || source["parentID"] == .null,
      source["basis"] == nil || source["basis"] == .null,
      !["partial", "erased"].contains(entry["appearance"]?["state"]?.string ?? "") else { return false }
    if source["kind"] == .string("nativeText") {
      return (source["textStyle"]?["format"] == nil || source["textStyle"]?["format"] == .null)
        && (source["textStyle"]?["runs"]?.array.isEmpty ?? true)
    }
    guard source["kind"] == .string("graphic"), let graphic = source["graphic"],
      graphic["sourceInkContactID"] == nil || graphic["sourceInkContactID"] == .null,
      graphic["mask"] == nil || graphic["mask"] == .null,
      graphic["freehand"] == nil || graphic["freehand"] == .null,
      graphic["transform"] == nil || graphic["transform"] == .null,
      graphic["representation"] == .string("geometry"), graphic["visible"] != .bool(false),
      entry["graphicResolution"]?["state"] == .string("geometry") else { return false }
    let connection = graphic["connection"]
    return connection?["start"]?["binding"] == nil && connection?["end"]?["binding"] == nil
  }
}

/// The panel pins an existing workspace and physical surface. Its requests
/// carry authored subjects; the admitted Mac owner supplies the human actor.
public struct NotebookPanelReadRequest: Codable, Sendable {
  public var workspaceID: UUID?
  public var target: CollaborationTarget?
  public var bounds: NotebookReadBounds?
  public var knownCursor: String?
  public init(workspaceID: UUID? = nil, target: CollaborationTarget? = nil, bounds: NotebookReadBounds? = nil, knownCursor: String? = nil) {
    self.workspaceID = workspaceID; self.target = target; self.bounds = bounds; self.knownCursor = knownCursor
  }
}

public struct NotebookPanelElementSource: Codable, Sendable {
  public let id: String
  public let page: AgentElement?
  public let spatial: SpatialElement?
  public init(id: String, page: AgentElement? = nil, spatial: SpatialElement? = nil) {
    self.id = id; self.page = page; self.spatial = spatial
  }
}

public struct NotebookPanelEditRequest: Codable, Sendable {
  public let workspaceID: UUID
  public let actionID: UUID
  public let target: CollaborationTarget
  public let summary: String
  public let operations: [CollaborationOperation]
  public let sources: [NotebookPanelElementSource]
  public init(workspaceID: UUID, actionID: UUID, target: CollaborationTarget, summary: String,
    operations: [CollaborationOperation], sources: [NotebookPanelElementSource]) {
    self.workspaceID = workspaceID; self.actionID = actionID; self.target = target
    self.summary = summary; self.operations = operations; self.sources = sources
  }
}

public struct NotebookPanelUndoRequest: Codable, Sendable {
  public let workspaceID: UUID
  public let target: CollaborationTarget
  public let actionID: UUID
  public init(workspaceID: UUID, target: CollaborationTarget, actionID: UUID) {
    self.workspaceID = workspaceID; self.target = target; self.actionID = actionID
  }
}

extension NotebookStore {
  public func unchangedPanelPresentation(_ request: NotebookPanelPresentationRequest, rendering: TargetRenderRequest) throws -> JSONValue? {
    guard request.knownRequestID == rendering.id, let cursor = request.knownCursor,
      let projection = rendering.panelProjection else { return nil }
    return try readTransaction { _ in
      guard try requirePanelWorkspace(request.workspaceID) == projection.workspaceID,
        cursor == String(try currentReadCursor()),
        try !currentSQL!.rows("SELECT 1 FROM metadata_index WHERE kind='renderRequest' AND address=? AND status='ready' LIMIT 1",
          [.text("collaboration/render-requests/" + rendering.id.uuidString.lowercased() + ".json#")]).isEmpty,
        FileManager.default.fileExists(atPath: targetReceiptURL(rendering.id).path) else { return nil }
      return .object(["workspaceID": try .encode(projection.workspaceID), "target": try .encode(rendering.target),
        "cursor": .string(cursor), "unchanged": .bool(true)])
    }
  }

  private func panelTarget(_ supplied: CollaborationTarget?, presence: SessionPresence?) throws -> CollaborationTarget {
    if let supplied { return supplied }
    if let presence {
      if presence.mode == .page, let id = presence.notebookPageID { return .init(kind: .page, id: id) }
      return .init(kind: .board, id: presence.boardID)
    }
    return try .init(kind: .board, id: workspaceHeader().rootBoardID)
  }

  public func requestPanelPresentation(_ request: NotebookPanelPresentationRequest) throws -> TargetRenderRequest {
    try request.appearance.validated()
    return try commandTransaction {
      let workspaceID = try requirePanelWorkspace(request.workspaceID)
      let presence = try readObservedPresenceIfAvailable()
      let target = try panelTarget(request.target, presence: presence)
      try requirePanelTarget(target)
      let camera: SpatialCamera
      if let supplied = request.appearance.camera { camera = supplied }
      else if target.kind == .board {
        if presence?.boardID == target.id, presence?.mode == .board { camera = presence!.camera }
        else { camera = BoardPortalProjection.entryCamera(portalCamera: try readBoardNodeHeader(target.id)?.portalCamera ?? .init(), viewport: request.appearance.viewport) }
      } else {
        let page = try loadPage(target.id)
        camera = .init(center: .init(x: page.size.width / 2, y: page.size.height / 2),
          scale: min(request.appearance.viewport.x / page.size.width, request.appearance.viewport.y / page.size.height))
      }
      let projection = NotebookPanelRenderProjection(workspaceID: workspaceID, camera: camera,
        viewport: request.appearance.viewport, pixelScale: request.appearance.pixelScale)
      return try enqueuePanelRender(target: target, projection: projection)
    }
  }
  private func requirePanelWorkspace(_ id: UUID?) throws -> UUID {
    let actual = try storedWorkspaceID()
    guard id == nil || id == actual else {
      throw CollaborationError("basis_workspace_mismatch", "Панель принадлежит другому пространству.")
    }
    return actual
  }

  private func requirePanelTarget(_ target: CollaborationTarget) throws {
    guard [.page, .board].contains(target.kind), target.boardID == nil else {
      throw CollaborationError("invalid_panel_surface", "Панели нужен точный адрес листа или доски.")
    }
  }

  public func readPanel(_ request: NotebookPanelReadRequest, actor: UUID) throws -> JSONValue {
    try readTransaction { _ in
      let workspaceID = try requirePanelWorkspace(request.workspaceID)
      let presence = try readObservedPresenceIfAvailable()
      let target = try panelTarget(request.target, presence: presence)
      try requirePanelTarget(target)
      if target.kind == .board { try requireLiveBoard(target.id) }
      else { _ = try readContentHeader(target: target) }
      let cursor = String(try currentReadCursor())
      if request.knownCursor == cursor {
        return .object(["workspaceID": try .encode(workspaceID), "target": try .encode(target),
          "cursor": .string(cursor), "unchanged": .bool(true)])
      }
      var elements: [JSONValue] = [], cards: [JSONValue] = [], size: JSONValue = .null, worldOrigin: JSONValue = .null
      var navigation: JSONValue = .null
      var truncated = false, rawInkPresent = false
      if target.kind == .page {
        let page = try loadPage(target.id)
        if let itemID = try ownerItemID(ofPage: target.id), let boardID = try ownerBoardID(of: itemID),
          let position = try resolveNotebookPage(target.id, in: itemID) {
          navigation = .object(["parentBoard": try .encode(CollaborationTarget(kind: .board, id: boardID)),
            "itemID": try .encode(itemID), "position": try .encode(position),
            "directory": try .encode(readNotebookPageDirectory(itemID: itemID, from: max(0, position.index - 1), limit: 3))])
        }
        let ink = try page.inkDrawing()
        rawInkPresent = ink.baselinePNG?.isEmpty == false || ink.actions.contains { $0.isActive && $0.tool == .pen }
        size = try .encode(page.size)
        for element in page.elements {
          let read = try readPageElementSnapshot(pageID: target.id, elementID: element.id)
          var value: [String: JSONValue] = ["source": try .encode(element)]
          if element.graphic != nil { value["graphicResolution"] = try readGraphicResolution(target: target, elementID: element.id).readProjection(includeGeometry: true) }
          value["appearance"] = read?.appearance
          elements.append(.object(value))
        }
      } else {
        let bounds: WorkspaceSpatialBounds
        if let supplied = request.bounds { bounds = try supplied.validated() }
        else {
          let width = max(1, (presence?.viewport.x ?? 1100) / max(0.01, presence?.camera.scale ?? 1))
          let height = max(1, (presence?.viewport.y ?? 780) / max(0.01, presence?.camera.scale ?? 1))
          bounds = .init(origin: (presence?.camera.center ?? .zero).offsetBy(x: -width / 2, y: -height / 2), width: width, height: height)
        }
        let scene = try readSceneWindow(boardID: target.id, bounds: bounds, limit: 128)
        worldOrigin = try .encode(bounds.origin)
        size = .object(["width": .number(bounds.width), "height": .number(bounds.height)])
        truncated = scene.truncated
        let board = scene.boards.first(where: { $0.id == target.id })?.board
        for placement in board?.freeItems ?? [] {
          if let item = try readItemHeader(placement.itemID) {
            cards.append(.object(["item": try .encode(item), "center": try .encode(placement.center)]))
          }
        }
        for stack in board?.stacks ?? [] {
          for id in stack.itemIDs {
            if let item = try readItemHeader(id) {
              cards.append(.object(["item": try .encode(item), "center": try .encode(stack.center), "stackID": try .encode(stack.id)]))
            }
          }
        }
        rawInkPresent = try !currentSQL!.rows("SELECT 1 FROM ink_surfaces WHERE kind='board' AND owner_id=? AND active=1 AND tool='pen' AND has_ink=1 LIMIT 1",
          [.text(target.id.uuidString.lowercased())]).isEmpty
        for element in board?.elements ?? [] where element.surface == .board(target.id) {
          var value: [String: JSONValue] = ["source": try .encode(element)]
          let layout: NotebookGraphicLayout?
          if element.graphic != nil {
            let resolution = try readGraphicResolution(target: target, elementID: element.id)
            value["graphicResolution"] = try resolution.readProjection(includeGeometry: true)
            layout = resolution.layout
          } else { layout = nil }
          let frame = layout?.frame ?? .init(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height)
          value["appearance"] = try NotebookElementAppearance.readProjection(graphic: element.graphic, layout: layout,
            size: .init(width: frame.width, height: frame.height), erasures: readElementErasures(on: .board(target.id), elementID: element.id))
          elements.append(.object(value))
        }
      }
      var history: [String: JSONValue] = [:]
      if case .command(let actionID)? = try nativeHistory(domain: .init(target), actor: actor).last {
        let head = try actionReadModel(actionID)
        if head.author == .human, head.action.operations.allSatisfy({ $0.target == target }) {
          history["undoActionID"] = try .encode(actionID)
        }
      }
      let unsupported = elements.compactMap { entry -> JSONValue? in
        guard let source = entry["source"], let id = source["id"]?.string, let kind = source["kind"]?.string else { return nil }
        let graphic = source["graphic"]
        let reason: String?
        if !["nativeText", "graphic"].contains(kind) { reason = "native_content" }
        else if source["parentID"]?.string != nil || source["basis"]?.object.isEmpty == false { reason = "grouped_content" }
        else if graphic?["representation"] == .string("ink") || graphic?["mask"]?.object.isEmpty == false
          || ["freehand", "path"].contains(graphic?["shape"]?.string ?? "") { reason = "native_graphic" }
        else { reason = nil }
        return reason.map { .object(["id": .string(id), "kind": .string(kind), "reason": .string($0)]) }
      }
      return .object(["workspaceID": try .encode(workspaceID), "target": try .encode(target),
        "elements": .array(elements), "size": size, "worldOrigin": worldOrigin, "basis": try .encode(readBasis(targets: [target], includeSource: true)),
        "cards": .array(cards), "rawInkPresent": .bool(rawInkPresent), "unsupportedElements": .array(unsupported),
        "cursor": .string(cursor), "history": .object(history), "truncated": .bool(truncated), "navigation": navigation])
    }
  }

  public func editPanel(_ request: NotebookPanelEditRequest, actor: UUID) throws -> JSONValue {
    try commandTransaction(readAllowance: .agentCommand) {
      _ = try requirePanelWorkspace(request.workspaceID)
      try requirePanelTarget(request.target)
      struct Fingerprint: Encodable { let actor: UUID; let request: NotebookPanelEditRequest }
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      let fingerprint = SHA256.hash(data: try encoder.encode(Fingerprint(actor: actor, request: request))).map { String(format: "%02x", $0) }.joined()
      // A response loss attaches to its exact saved native command. Stale
      // preconditions never turn the same gesture into another write.
      if let saved = try collaborationActionIfPresent(request.actionID) {
        guard saved.author == .human, saved.requestFingerprint == fingerprint else {
          throw CollaborationError("action_id_conflict", "Этот ID уже принадлежит другому действию.")
        }
        guard let original = try savedActionResult(saved.id) else { throw CollaborationError("action_version_unavailable", "Исходный результат действия недоступен.") }
        return original
      }
      guard !request.operations.isEmpty, request.operations.count <= 32,
        !request.sources.isEmpty, request.sources.count <= 64,
        request.operations.allSatisfy({ operation in
          guard operation.target == request.target, [.insertElement, .updateElement, .removeElement].contains(operation.kind) else { return false }
          if operation.kind == .insertElement { return ["nativeText", "graphic"].contains(operation.values["kind"]?.string ?? "") }
          return true
        }), request.sources.allSatisfy({ source in
          if request.target.kind == .page { return source.spatial == nil && source.page.map { $0.id == source.id && [.nativeText, .graphic].contains($0.kind) } != false }
          return source.page == nil && source.spatial.map { $0.id == source.id && $0.surface == .board(request.target.id) && [.nativeText, .graphic].contains($0.kind) } != false
        }) else {
        throw CollaborationError("invalid_panel_edit", "Панель редактирует текст и фигуры одной поверхности.")
      }
      let sources = request.sources.map { NotebookNativeElementSource(target: request.target, id: $0.id, page: $0.page, spatial: $0.spatial) }
      let result = try applyNativeElementEdits(request.operations, summary: request.summary, sources: sources,
        actionID: request.actionID, actor: actor, requestFingerprint: fingerprint)
      guard let original = try savedActionResult(result.receipt.id) else { throw CollaborationError("action_version_unavailable", "Исходный результат действия недоступен.") }
      return original
    }
  }

  public func undoPanel(_ request: NotebookPanelUndoRequest, actor: UUID) throws -> JSONValue {
    try commandTransaction(readAllowance: .agentCommand) {
      _ = try requirePanelWorkspace(request.workspaceID)
      try requirePanelTarget(request.target)
      let receipt = try collaborationAction(request.actionID)
      guard receipt.author == .human, receipt.action.operations.allSatisfy({ $0.target == request.target }) else {
        throw CollaborationError("invalid_panel_undo", "Отмена принадлежит действиям пользователя на этой поверхности.")
      }
      if receipt.undo != nil { return try scriptActionOutcome(receipt) }
      guard case .command(let id)? = try nativeHistory(domain: .init(request.target), actor: actor).last, id == request.actionID else {
        throw CollaborationError("revision_conflict", "История поверхности изменилась. Обновите панель.")
      }
      return try scriptActionOutcome(undoNativeAction(request.actionID, actor: actor))
    }
  }
}
