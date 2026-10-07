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
      (1...2048).contains(viewport.y), pixelScale.isFinite, (0.5...4).contains(pixelScale),
      viewport.x * viewport.y * pixelScale * pixelScale <= 16_777_216.000001,
      camera?.isValid != false else { throw CollaborationError("resource_limit", "Проекция панели превышает предел размера или разрешения.") }
  }
}

public struct NotebookPanelPresentationRequest: Codable, Sendable {
  public let workspaceID: UUID?
  public let target: CollaborationTarget?
  public let appearance: NotebookPanelAppearanceProjection
  public let knownCursor: String?
  public let knownRequestID: UUID?
  public let knownAssets: [UUID]?
  public let includeFitBounds: Bool?
  public init(workspaceID: UUID? = nil, target: CollaborationTarget? = nil,
    appearance: NotebookPanelAppearanceProjection, knownCursor: String? = nil, knownRequestID: UUID? = nil,
    knownAssets: [UUID]? = nil, includeFitBounds: Bool? = nil) {
    self.workspaceID = workspaceID; self.target = target; self.appearance = appearance; self.knownCursor = knownCursor
    self.knownRequestID = knownRequestID
    self.knownAssets = knownAssets
    self.includeFitBounds = includeFitBounds
  }
}

/// One admitted presentation borrows native material from the shared pixel owner.
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

public struct NotebookPanelPresentationCut: Sendable {
  public let id: UUID
  public let target: CollaborationTarget
  public let sourceRevision: String
  public let cursor: UInt64
  public let projection: NotebookPanelRenderProjection
  public let includeFitBounds: Bool

  init(target: CollaborationTarget, sourceRevision: String, cursor: UInt64,
    projection: NotebookPanelRenderProjection, includeFitBounds: Bool = false) throws {
    let hash = try collaborationHash(JSONValue.object(["renderer": .string("NotebookPanelMaterials/3"),
      "target": try .encode(target), "source": .string(sourceRevision), "projection": try .encode(projection),
      "fit": .bool(includeFitBounds)]))
    let hex = Array(hash)
    let first = String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-4" + String(hex[13..<16])
    let second = "-8" + String(hex[17..<20]) + "-" + String(hex[20..<32])
    id = UUID(uuidString: first + second)!
    self.target = target; self.sourceRevision = sourceRevision; self.cursor = cursor; self.projection = projection
    self.includeFitBounds = includeFitBounds
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
  public var includeFitBounds: Bool?
  public init(workspaceID: UUID? = nil, target: CollaborationTarget? = nil, bounds: NotebookReadBounds? = nil,
    knownCursor: String? = nil, includeFitBounds: Bool? = nil) {
    self.workspaceID = workspaceID; self.target = target; self.bounds = bounds; self.knownCursor = knownCursor
    self.includeFitBounds = includeFitBounds
  }
}

public struct NotebookPanelEditSource: Codable, Sendable {
  public let id: String
  public let page: AgentElement?
  public let spatial: SpatialElement?
  public let placements: [WorkspacePlacement]?
  public init(id: String, page: AgentElement? = nil, spatial: SpatialElement? = nil, placements: [WorkspacePlacement]? = nil) {
    self.id = id; self.page = page; self.spatial = spatial; self.placements = placements
  }
}

public struct NotebookPanelEditRequest: Codable, Sendable {
  public let workspaceID: UUID
  public let actionID: UUID
  public let target: CollaborationTarget
  public let summary: String
  public let operations: [CollaborationOperation]
  public let sources: [NotebookPanelEditSource]
  public init(workspaceID: UUID, actionID: UUID, target: CollaborationTarget, summary: String,
    operations: [CollaborationOperation], sources: [NotebookPanelEditSource]) {
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
  private func panelTarget(_ supplied: CollaborationTarget?, presence: SessionPresence?) throws -> CollaborationTarget {
    if let supplied { return supplied }
    if let presence {
      if presence.mode == .page, let id = presence.notebookPageID { return .init(kind: .page, id: id) }
      return .init(kind: .board, id: presence.boardID)
    }
    return try .init(kind: .board, id: workspaceHeader().rootBoardID)
  }

  public func requestPanelPresentation(_ request: NotebookPanelPresentationRequest) throws -> NotebookPanelPresentationCut {
    try request.appearance.validated()
    guard (request.knownAssets?.count ?? 0) <= 96 else {
      throw CollaborationError("resource_limit", "Панель удерживает не больше 96 native материалов.")
    }
    return try readTransaction { _ in
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
        guard let size = try readContentHeader(target: target).size else {
          throw NotebookStorageError.corruptRecord("panel page size")
        }
        camera = .init(center: .init(x: size.width / 2, y: size.height / 2),
          scale: max(SpatialCamera.minimumScale,
            min(request.appearance.viewport.x / size.width, request.appearance.viewport.y / size.height)))
      }
      let projection = NotebookPanelRenderProjection(workspaceID: workspaceID, camera: camera,
        viewport: request.appearance.viewport, pixelScale: request.appearance.pixelScale)
      return try .init(target: target, sourceRevision: referenceRevision(target: target),
        cursor: currentReadCursor(), projection: projection, includeFitBounds: request.includeFitBounds == true)
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

  public func readPanel(_ request: NotebookPanelReadRequest, actor: UUID,
    reusing pageContent: NotebookPanelPageContent? = nil) throws -> JSONValue {
    try readTransaction { _ in
      let workspaceID = try requirePanelWorkspace(request.workspaceID)
      let presence = try readObservedPresenceIfAvailable()
      let target = try panelTarget(request.target, presence: presence)
      try requirePanelTarget(target)
      if target.kind == .board { try requireLiveBoard(target.id) }
      else { _ = try readContentHeader(target: target) }
      try pageContent?.validate(in: self, workspaceID: workspaceID, target: target)
      let cursor = String(try currentReadCursor())
      if request.knownCursor == cursor && request.includeFitBounds != true {
        return .object(["workspaceID": try .encode(workspaceID), "target": try .encode(target),
          "cursor": .string(cursor), "unchanged": .bool(true)])
      }
      var elements: [JSONValue] = [], cards: [JSONValue] = [], size: JSONValue = .null, worldOrigin: JSONValue = .null
      var navigation: JSONValue = .null
      var truncated = false, rawInkPresent = false
      if target.kind == .page {
        let page = try pageContent?.page ?? loadPage(target.id)
        if let itemID = try ownerItemID(ofPage: target.id), let boardID = try ownerBoardID(of: itemID),
          let position = try resolveNotebookPage(target.id, in: itemID) {
          navigation = .object(["parentBoard": try .encode(CollaborationTarget(kind: .board, id: boardID)),
            "itemID": try .encode(itemID), "position": try .encode(position),
            "directory": try .encode(readNotebookPageDirectory(itemID: itemID, from: max(0, position.index - 1), limit: 3))])
        }
        size = try .encode(page.size)
        if let pageContent { elements = pageContent.elements; rawInkPresent = pageContent.rawInkPresent }
        else { (elements, rawInkPresent) = try NotebookPanelPageContent.projection(page) }
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
        func cardSource(_ id: UUID) throws -> JSONValue {
          guard let owner = try readBoardItem(id), owner.id == target.id else {
            throw CollaborationError("revision_conflict", "Предмет больше не принадлежит доске панели.")
          }
          return try .encode(NotebookPanelEditSource(id: id.uuidString,
            placements: owner.board.placements.sorted { $0.id.uuidString < $1.id.uuidString }))
        }
        for placement in board?.freeItems ?? [] {
          if let item = try readItemHeader(placement.itemID) {
            cards.append(.object(["item": try .encode(item), "center": try .encode(placement.center),
              "source": try cardSource(placement.itemID)]))
          }
        }
        for stack in board?.stacks ?? [] {
          for id in stack.itemIDs {
            if let item = try readItemHeader(id) {
              cards.append(.object(["item": try .encode(item), "center": try .encode(stack.center),
                "stackID": try .encode(stack.id), "source": try cardSource(id)]))
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
      let snapshot = JSONValue.object(["workspaceID": try .encode(workspaceID), "target": try .encode(target),
        "elements": .array(elements), "size": size, "worldOrigin": worldOrigin, "basis": try .encode(readBasis(targets: [target], includeSource: true)),
        "cards": .array(cards), "rawInkPresent": .bool(rawInkPresent), "unsupportedElements": .array(unsupported),
        "cursor": .string(cursor), "history": .object(history), "truncated": .bool(truncated), "navigation": navigation])
      guard request.includeFitBounds == true else { return snapshot }
      return snapshot.setting("fitBounds", try panelMaterialBounds(target: target).map { try .encode($0) } ?? .null)
    }
  }

  /// Explicit overview reads authored material metadata beyond the current view.
  /// Pen bounds retain eraser padding; this is not a scan of visible pixels.
  public func panelMaterialBounds(target: CollaborationTarget) throws -> NotebookReadBounds? {
    try readTransaction { _ in
      try requirePanelTarget(target)
      if target.kind == .page {
        let size = try readContentHeader(target: target).size!
        return .init(anchor: .zero, region: .init(x: 0, y: 0, width: size.width, height: size.height))
      }
      try requireLiveBoard(target.id)
      let owner = NotebookSQLValue.text(target.id.uuidString.lowercased())
      func extent(table: String, predicate: String) throws -> WorkspaceSpatialBounds? {
        func endpoint(_ columns: String, descending: Bool = false) throws -> [NotebookSQLValue]? {
          let order = columns.split(separator: ",").map { String($0) + (descending ? " DESC" : "") }.joined(separator: ",")
          return try currentSQL!.rows("SELECT " + columns + " FROM " + table + " WHERE " + predicate
            + " ORDER BY " + order + " LIMIT 1", [owner]).first
        }
        guard let x0 = try endpoint("min_tx,min_x"), let y0 = try endpoint("min_ty,min_y"),
          let x1 = try endpoint("max_tx,max_x", descending: true), let y1 = try endpoint("max_ty,max_y", descending: true) else { return nil }
        return .init(origin: .init(tileX: x0[0].integer!, tileY: y0[0].integer!, localX: x0[1].spatialNumber, localY: y0[1].spatialNumber),
          maximum: .init(tileX: x1[0].integer!, tileY: y1[0].integer!, localX: x1[1].spatialNumber, localY: y1[1].spatialNumber))
      }
      let spatial = try extent(table: "spatial_entries", predicate: "board_id=? AND parent_id IS NULL AND has_paint=1 AND kind<>'coverElement'")
      let ink = try extent(table: "ink_surfaces", predicate: "kind='board' AND owner_id=? AND active=1 AND tool='pen' AND has_ink=1")
      guard let bounds = spatial.map({ ink.map($0.union) ?? $0 }) ?? ink else { return nil }
      let size = bounds.origin.delta(to: bounds.maximum)
      return .init(anchor: bounds.origin, region: .init(x: 0, y: 0, width: max(1, size.x), height: max(1, size.y)))
    }
  }

  public func editPanel(_ request: NotebookPanelEditRequest, actor: UUID) throws -> JSONValue {
    try commandTransaction(readAllowance: .nativeCommand) {
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
      if request.operations.contains(where: { $0.kind == .appendInkStroke }) {
        guard request.operations.count == 1, request.sources.isEmpty,
          let operation = request.operations.first, operation.target == request.target else {
          throw CollaborationError("invalid_panel_edit", "Контакт ручки добавляет один штрих на свою поверхность.")
        }
        // An append owns its new stroke UUID. It does not adopt or compare a
        // page-wide revision, so another contact cannot invalidate this lift.
        let receipt = try applyNativeAction(.init(id: request.actionID, summary: request.summary,
          expected: [], operations: request.operations), actor: actor, requestFingerprint: fingerprint)
        guard let original = try savedActionResult(receipt.id) else {
          throw CollaborationError("action_version_unavailable", "Исходный результат действия недоступен.")
        }
        return original
      }
      if request.operations.contains(where: { $0.kind == .moveItem }) {
        guard request.target.kind == .board, request.operations.count == 1, request.sources.count == 1,
          let operation = request.operations.first, operation.target == request.target,
          let itemID = operation.id.flatMap(UUID.init(uuidString:)),
          let source = request.sources.first, UUID(uuidString: source.id) == itemID,
          source.page == nil, source.spatial == nil, let placements = source.placements,
          (1...10).contains(placements.count), placements.contains(where: { $0.id == itemID }) else {
          throw CollaborationError("invalid_panel_edit", "Перенос панели называет один предмет и полный исходник его стопки.")
        }
        let result = try applyNativePlacementEdits(request.operations, summary: request.summary, sources: placements,
          actionID: request.actionID, actor: actor, requestFingerprint: fingerprint)
        guard let original = try savedActionResult(result.receipt.id) else { throw CollaborationError("action_version_unavailable", "Исходный результат действия недоступен.") }
        return original
      }
      guard !request.operations.isEmpty, request.operations.count <= 32,
        !request.sources.isEmpty, request.sources.count <= 64,
        request.operations.allSatisfy({ operation in
          guard operation.target == request.target, [.insertElement, .updateElement, .removeElement].contains(operation.kind) else { return false }
          if operation.kind == .insertElement { return ["nativeText", "graphic"].contains(operation.values["kind"]?.string ?? "") }
          return true
        }), request.sources.allSatisfy({ source in
          guard source.placements == nil else { return false }
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
    try commandTransaction(readAllowance: .nativeCommand) {
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
